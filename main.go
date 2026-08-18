package main

import (
	"context"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

func main() {
	configPath := flag.String("config", "config.json", "path to config.json")
	listen := flag.String("listen", "", "override the configured API listen address")
	webListen := flag.String("web-listen", "", "override the configured WebUI listen address")
	combinedMode := flag.Bool("combined", false, "serve API and WebUI on a single port (for platforms like Back4app that expose one port)")
	flag.Parse()

	// Back4app and similar container platforms expose a single PORT env var.
	// When PORT is set and no explicit listen address is given, use it.
	if envPort := os.Getenv("PORT"); envPort != "" && *listen == "" {
		*listen = "0.0.0.0:" + envPort
	}

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		slog.Error("configuration error", "error", err)
		os.Exit(1)
	}
	if *listen != "" {
		cfg.Listen = *listen
	}
	if *webListen != "" {
		cfg.WebUI.Listen = *webListen
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	level := new(slog.LevelVar)
	setLogLevel(level, cfg.Logging.Level)
	hub := NewLogHub(cfg.Logging.RingSize)
	redactor := NewSecretRedactor()
	redactor.Replace(cfg)
	logger := NewStructuredLogger(level, hub, redactor)
	monitor := NewMonitor()
	manager, err := NewRuntimeManager(ctx, *configPath, cfg, logger, monitor, hub, redactor, level)
	if err != nil {
		logger.Error("failed to initialize runtime", "component", "runtime", "event", "runtime_initialization_failed", "error", err)
		os.Exit(1)
	}
	defer manager.Shutdown()

	servers := []*http.Server{}

	if *combinedMode && cfg.WebUI.Enabled {
		// Single-port mode: mount API + WebUI routes on one server.
		admin := NewAdminServer(manager, monitor, hub, logger)
		combined := newCombinedHandler(manager.Handler(), admin.Handler(), logger)
		server := &http.Server{
			Addr: cfg.Listen, Handler: combined, ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 120 * time.Second,
		}
		servers = append(servers, server)
		go serveHTTP(cancel, logger, server, "combined")
	} else {
		apiServer := &http.Server{
			Addr: cfg.Listen, Handler: manager.Handler(), ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 120 * time.Second,
		}
		servers = append(servers, apiServer)
		go serveHTTP(cancel, logger, apiServer, "api")

		if cfg.WebUI.Enabled {
			admin := NewAdminServer(manager, monitor, hub, logger)
			webServer := &http.Server{
				Addr: cfg.WebUI.Listen, Handler: admin.Handler(), ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 120 * time.Second,
			}
			servers = append(servers, webServer)
			go serveHTTP(cancel, logger, webServer, "webui")
		}
	}

	<-ctx.Done()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()
	for _, server := range servers {
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Error("graceful shutdown failed", "component", "server", "event", "shutdown_failed", "address", server.Addr, "error", err)
		}
	}
}

func serveHTTP(cancel context.CancelFunc, logger *slog.Logger, server *http.Server, component string) {
	logger.Info("server listening", "component", component, "event", "server_started", "address", server.Addr, "version", version)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Error("server stopped unexpectedly", "component", component, "event", "server_failed", "address", server.Addr, "error", err)
		cancel()
	}
}

// newCombinedHandler merges API and WebUI routes on a single port.
// API routes: /v1/*, /healthz
// WebUI routes: /api/*, / (static files)
func newCombinedHandler(apiHandler, webHandler http.Handler, logger *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		// API routes
		if strings.HasPrefix(path, "/v1/") || path == "/healthz" {
			apiHandler.ServeHTTP(w, r)
			return
		}
		// WebUI routes (everything else)
		webHandler.ServeHTTP(w, r)
	})
}
