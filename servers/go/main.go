package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

var plaintext = []byte("hello, world!\n")

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

	server := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%s", port),
		Handler: mux,
	}
	log.Fatal(server.ListenAndServe())
}
