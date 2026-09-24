FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/app .

FROM scratch
# CA bundle for the outbound HTTPS call to the rate provider
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
