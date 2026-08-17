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
	for index := range 128 {
		mux.HandleFunc(fmt.Sprintf("GET /ridiculous/decoy-%d", index), func(response http.ResponseWriter, _ *http.Request) {
			response.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = response.Write([]byte("decoy\n"))
		})
	}
	mux.HandleFunc("GET /ridiculous/{account}/orders/{order}", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(
			response,
			"%s:%s:%s\n",
			request.PathValue("account"),
			request.PathValue("order"),
			request.URL.Query().Get("expand"),
		)
	})
	mux.HandleFunc("GET /p/{p0}/s1/{p1}/s2/{p2}/s3/{p3}/s4/{p4}/s5/{p5}/s6/{p6}/s7/{p7}", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		query := request.URL.Query()
		_, _ = fmt.Fprintf(
			response,
			"%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n",
			request.PathValue("p0"), request.PathValue("p1"),
			request.PathValue("p2"), request.PathValue("p3"),
			request.PathValue("p4"), request.PathValue("p5"),
			request.PathValue("p6"), request.PathValue("p7"),
			query.Get("q0"), query.Get("q1"), query.Get("q2"), query.Get("q3"),
			query.Get("q4"), query.Get("q5"), query.Get("q6"), query.Get("q7"),
		)
	})
	mux.HandleFunc("GET /headers-32", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(
			response,
			"%s:%s:%s:%s:%s\n",
			request.Header.Get("X-Bench-00"), request.Header.Get("X-Bench-07"),
			request.Header.Get("X-Bench-15"), request.Header.Get("X-Bench-23"),
			request.Header.Get("X-Bench-31"),
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
