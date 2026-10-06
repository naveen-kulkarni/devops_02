package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type server struct {
	db        atomic.Pointer[pgxpool.Pool]
	model     string
	rateLimit string
}

type generation struct {
	ID        int64  `json:"id"`
	Model     string `json:"model"`
	Tokens    int    `json:"tokens"`
	LatencyMS int64  `json:"latency_ms"`
}

func main() {
	s := &server{
		model:     env("MODEL_NAME", "gen-small"),
		rateLimit: env("RATE_LIMIT", "50"),
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go s.connect(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("GET /v1/generate", s.generate)

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("listening on %s", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	if db := s.db.Load(); db != nil {
		db.Close()
	}
	log.Printf("stopped")
}

func (s *server) connect(ctx context.Context) {
	log.Printf("loading model %s", s.model)
	time.Sleep(3 * time.Second)

	host := env("DB_HOST", "postgres")
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
		env("DB_USER", "inference"), os.Getenv("DB_PASSWORD"),
		host, env("DB_PORT", "5432"), env("DB_NAME", "inference"))

	for {
		db, err := open(ctx, host, dsn)
		if err == nil {
			s.db.Store(db)
			log.Printf("database connected")
			return
		}
		log.Printf("database connection failed: %v", err)

		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
}

func open(ctx context.Context, host, dsn string) (*pgxpool.Pool, error) {
	lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := net.DefaultResolver.LookupHost(lookupCtx, host); err != nil {
		return nil, fmt.Errorf("resolve database host: %w", err)
	}

	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := db.Ping(pingCtx); err != nil {
		db.Close()
		return nil, err
	}
	_, err = db.Exec(ctx, `CREATE TABLE IF NOT EXISTS generations (
		id BIGSERIAL PRIMARY KEY,
		model TEXT NOT NULL,
		tokens INT NOT NULL,
		latency_ms BIGINT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	if err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok\n"))
}

func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	db := s.db.Load()
	if db == nil {
		http.Error(w, "database not connected", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := db.Ping(ctx); err != nil {
		http.Error(w, "database ping failed", http.StatusServiceUnavailable)
		return
	}
	w.Write([]byte("ok\n"))
}

func (s *server) generate(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-RateLimit-Limit", s.rateLimit)

	db := s.db.Load()
	if db == nil {
		http.Error(w, "model is warming up", http.StatusServiceUnavailable)
		return
	}

	start := time.Now()
	latency := time.Duration(50+rand.IntN(100)) * time.Millisecond
	if rand.IntN(20) == 0 {
		latency = time.Duration(8000+rand.IntN(7000)) * time.Millisecond
	}
	time.Sleep(latency)

	g := generation{
		Model:     s.model,
		Tokens:    16 + rand.IntN(240),
		LatencyMS: time.Since(start).Milliseconds(),
	}
	err := db.QueryRow(r.Context(),
		"INSERT INTO generations (model, tokens, latency_ms) VALUES ($1, $2, $3) RETURNING id",
		g.Model, g.Tokens, g.LatencyMS).Scan(&g.ID)
	if err != nil {
		log.Printf("insert generation: %v", err)
		http.Error(w, "failed to store generation", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(g)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
