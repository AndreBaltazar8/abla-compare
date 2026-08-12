package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
)

var plaintext = []byte("hello, world!\n")

type contextKey string

type user struct {
	ID   string
	Name string
	Tier string
}

const userKey contextKey = "user"

func authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer benchmark-token" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		value := user{ID: "user-7", Name: "Andre", Tier: "gold"}
		next.ServeHTTP(response, request.WithContext(
			context.WithValue(request.Context(), userKey, value),
		))
	})
}

func main() {
	port := "18080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		response.Header().Set("Content-Length", "14")
		_, _ = response.Write(plaintext)
	})
	mux.HandleFunc("GET /accounts/{account}/items/{item}", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(
			response,
			"%s:%s:%s\n",
			request.PathValue("account"),
			request.PathValue("item"),
			request.URL.Query().Get("filter"),
		)
	})
	mux.Handle("GET /context", authenticated(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		value := request.Context().Value(userKey).(user)
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(response, "%s:%s:%s\n", value.ID, value.Name, value.Tier)
	})))
	mux.HandleFunc("POST /body", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/octet-stream")
		_, _ = io.Copy(response, request.Body)
	})

	server := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%s", port),
		Handler: mux,
	}
	log.Fatal(server.ListenAndServe())
}
