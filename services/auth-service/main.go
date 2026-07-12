package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/caarlos0/env/v11"
	"github.com/go-chi/chi/v5"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	internnats "banking-demo/internal/nats"
	"banking-demo/internal/health"
	ilogging "banking-demo/internal/logging"
	"banking-demo/internal/metrics"
	"banking-demo/internal/service"
	"banking-demo/internal/tracing"
)

const (
	serviceName      = "auth-service"
	subjectPrefix    = "banking.auth"
)

type config struct {
	Port         string `env:"PORT"         envDefault:"8001"`
	NATSURL      string `env:"NATS_URL"     envDefault:"nats://nats:4222"`
	DatabaseURL  string `env:"DATABASE_URL" envDefault:"postgresql://banking:bankingpass@postgres:5432/banking"`
	RedisURL     string `env:"REDIS_URL"    envDefault:"redis://redis:6379/0"`
	OTLPEndpoint string `env:"OTEL_EXPORTER_OTLP_ENDPOINT"`
}

func main() {
	var cfg config
	if err := env.Parse(&cfg); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: parse config: %v\n", err)
		os.Exit(1)
	}
	if err := run(context.Background(), cfg); err != nil {
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config) error {
	logger := ilogging.NewLogger(serviceName)

	shutdownTracing := tracing.Init(serviceName, cfg.OTLPEndpoint, logger)
	defer shutdownTracing(context.Background())

	d, cleanup, err := service.InitDeps(ctx, cfg.DatabaseURL, cfg.RedisURL, logger)
	if err != nil {
		return err
	}
	defer cleanup()
	d.LogPoolStatus(logger)

	m := metrics.NewConsumerMetrics(serviceName)

	requireSession := internnats.SessionMiddleware(d.RedisClient)

	consumer := internnats.NewConsumer(cfg.NATSURL, serviceName, subjectPrefix, logger,
		internnats.WithMetrics(m),
		internnats.WithHandler("register", handleRegister(d.BDB, logger)),
		internnats.WithHandler("login", handleLogin(d.BDB, d.RedisClient, logger)),
		internnats.WithHandler("logout", requireSession(handleLogout(d.RedisClient))),
		internnats.WithHandler("health", health.NATSHandler(serviceName, d.Pool, d.RedisClient)),
	)

	router := chi.NewRouter()
	router.Get("/health", health.HTTPHandler(serviceName, d.Pool, d.RedisClient))
	router.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
	}

	return service.NewRunner(consumer, server, logger).Run(ctx)
}
