FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/inference-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/inference-api /inference-api
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/inference-api"]
