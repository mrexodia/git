IMPORT := code.gitea.io/git

PACKAGES ?= $(shell go list -e ./... | grep -v /vendor/ | grep -v /benchmark/)
GENERATE ?= code.gitea.io/git

.PHONY: all
all: clean test build

.PHONY: clean
clean:
	go clean -i ./...

generate:
	@which mockery > /dev/null; if [ $$? -ne 0 ]; then \
		go get -u github.com/vektra/mockery/...; \
	fi
	go generate $(GENERATE)

.PHONY: fmt
fmt:
	find . -name "*.go" -type f ! -path "./vendor/*" ! -path "./benchmark/*" | xargs gofmt -s -w

.PHONY: vet
vet:
	go vet $(PACKAGES)

.PHONY: lint
lint:
	@which golint > /dev/null; if [ $$? -ne 0 ]; then \
		go get -u github.com/golang/lint/golint; \
	fi
	for PKG in $(PACKAGES); do golint -set_exit_status $$PKG || exit 1; done;

.PHONY: test
test:
	for PKG in $(PACKAGES); do go test -cover -coverprofile $$GOPATH/src/$$PKG/coverage.out $$PKG || exit 1; done;

.PHONY: bench
bench:
	go test -run=XXXXXX -benchtime=10s -bench=. || exit 1

.PHONY: build
build:
	go build .

ifeq ($(CI), drone)
.PHONY: test-install-git-1-7
test-install-git-1-7:
	mkdir build-git
	curl -sL "https://github.com/git/git/archive/v1.7.0.tar.gz" -o git.tar.gz
	tar -C build-git -xzf git.tar.gz
	cd build-git/git-1.7.0
	./autoconf
	./configure --prefix=/usr/local
	make install NO_PERL=please
	cd ../..
	rm -rf build
	rm git.tar.gz
endif
