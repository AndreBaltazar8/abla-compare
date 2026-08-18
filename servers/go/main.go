package main

import (
	"context"
	"encoding/json"
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

type nestedUser struct {
	ID    int      `json:"id"`
	Name  string   `json:"name"`
	Roles []string `json:"roles"`
}

type nestedItem struct {
	SKU   string `json:"sku"`
	Qty   int    `json:"qty"`
	Price int    `json:"price"`
}

type nestedRequest struct {
	RequestID string       `json:"request_id"`
	User      nestedUser   `json:"user"`
	Items     []nestedItem `json:"items"`
	Active    bool         `json:"active"`
	Note      string       `json:"note"`
}

type nestedResponse struct {
	Active      bool   `json:"active"`
	ItemCount   int    `json:"item_count"`
	PrimaryRole string `json:"primary_role"`
	RequestID   string `json:"request_id"`
	Total       int    `json:"total"`
	User        string `json:"user"`
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
	scenario := os.Getenv("ABLA_COMPARE_SCENARIO")

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
	if scenario == "route-tail-128" {
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
	}
	if scenario == "route-fanout-1024" {
		for index := range 1024 {
			mux.HandleFunc(fmt.Sprintf("GET /fanout/decoy-%d", index), func(response http.ResponseWriter, _ *http.Request) {
				response.Header().Set("Content-Type", "text/plain; charset=utf-8")
				_, _ = response.Write([]byte("decoy\n"))
			})
		}
		mux.HandleFunc("GET /fanout/target", func(response http.ResponseWriter, _ *http.Request) {
			response.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = response.Write([]byte("fanout-target\n"))
		})
	}
	mux.HandleFunc("GET /query-32", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		query := request.URL.Query()
		_, _ = fmt.Fprintf(
			response,
			"%s:%s:%s:%s:%s:%s:%s:%s\n",
			query.Get("field-00"), query.Get("field-07"),
			query.Get("field-13"), query.Get("field-19"),
			query.Get("field-25"), query.Get("field-27"),
			query.Get("field-29"), query.Get("field-31"),
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
	mux.HandleFunc("POST /json-nested", func(response http.ResponseWriter, request *http.Request) {
		var input nestedRequest
		if err := json.NewDecoder(request.Body).Decode(&input); err != nil {
			http.Error(response, "invalid json", http.StatusBadRequest)
			return
		}
		total := 0
		for _, item := range input.Items {
			total += item.Qty * item.Price
		}
		primaryRole := ""
		if len(input.User.Roles) > 0 {
			primaryRole = input.User.Roles[0]
		}
		body, _ := json.Marshal(nestedResponse{
			Active:      input.Active,
			ItemCount:   len(input.Items),
			PrimaryRole: primaryRole,
			RequestID:   input.RequestID,
			Total:       total,
			User:        input.User.Name,
		})
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write(body)
	})

	server := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%s", port),
		Handler: mux,
	}
	log.Fatal(server.ListenAndServe())
}
