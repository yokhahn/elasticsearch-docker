SHELL = /bin/bash
ELASTIC_REGISTRY ?= docker.elastic.co

TEDI_DEBUG ?= false
TEDI ?= docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(PWD):/mnt \
  -v $(PWD)/../..:/release-manager \
  -e TEDI_DEBUG=$(TEDI_DEBUG) \
  docker.elastic.co/tedi/tedi:0.6

export PATH := ./bin:./venv/bin:$(PATH)

# Determine the version to build. Override by setting ELASTIC_VERSION env var.
ELASTIC_VERSION := $(shell ./bin/elastic-version)

ifdef STAGING_BUILD_NUM
  VERSION_TAG := $(ELASTIC_VERSION)-$(STAGING_BUILD_NUM)
else
  VERSION_TAG := $(ELASTIC_VERSION)
endif

# Build different images tagged as :version-<flavor>
IMAGE_FLAVORS ?= oss full

# Which image flavor will additionally receive the plain `:version` tag
DEFAULT_IMAGE_FLAVOR ?= full

IMAGE_TAG ?= $(ELASTIC_REGISTRY)/elasticsearch/elasticsearch

# When invoking docker-compose, use an extra config fragment to map Elasticsearch's
# listening port to the docker host.
# For the x-pack security enabled image (platinum), use the fragment we utilize for tests.
ifeq ($(DEFAULT_IMAGE_FLAVOR),platinum)
  DOCKER_COMPOSE := docker-compose \
	-f docker-compose-$(DEFAULT_IMAGE_FLAVOR).yml \
	-f tests/docker-compose-$(DEFAULT_IMAGE_FLAVOR).yml
else
  DOCKER_COMPOSE := docker-compose \
	-f docker-compose-$(DEFAULT_IMAGE_FLAVOR).yml \
	-f docker-compose.hostports.yml
endif

.PHONY: all dockerfile docker-compose test test-build lint clean pristine build release-manager release-manager-snapshot push

# Default target, build *and* run tests
all: build test

# Test specified versions without building
test: lint
	docker run --rm -v "$(PWD):/mnt" bash rm -rf /mnt/tests/datadir1 /mnt/tests/datadir2
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  pyfiglet -w 160 -f puffy "test: $(FLAVOR) single"; \
	  ./bin/pytest --image-flavor=$(FLAVOR) --single-node tests; \
	  pyfiglet -w 160 -f puffy "test: $(FLAVOR) multi"; \
	  ./bin/pytest --image-flavor=$(FLAVOR) tests; \
	)

# Build and test
test-build: lint build docker-compose

lint: venv
	flake8 tests

clean:
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	if [[ -f "docker-compose-$(FLAVOR).yml" ]]; then \
	  docker-compose -f docker-compose-$(FLAVOR).yml down && docker-compose -f docker-compose-$(FLAVOR).yml rm -f -v; \
	fi; \
	rm -f docker-compose-$(FLAVOR).yml; \
	rm -f tests/docker-compose-$(FLAVOR).yml; \
	rm -f build/elasticsearch/Dockerfile-$(FLAVOR); \
	)

pristine: clean
	-$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	docker rmi -f $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	)
	-docker rmi -f $(IMAGE_TAG):$(VERSION_TAG)
	rm -rf venv

# Build docker image: "elasticsearch-$(FLAVOR):$(VERSION_TAG)"
build: clean dockerfile
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  pyfiglet -f puffy -w 160 "Building: $(FLAVOR)"; \
	  docker build -t $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) -f build/elasticsearch/Dockerfile-$(FLAVOR) build/elasticsearch; \
	  if [[ $(FLAVOR) == $(DEFAULT_IMAGE_FLAVOR) ]]; then \
	    docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) $(IMAGE_TAG):$(VERSION_TAG); \
	  fi; \
	)


release-manager-release: clean
	$(TEDI) build --asset-set=local_release

release-manager-snapshot: clean
	$(TEDI) build --asset-set=local_snapshot --fact=image_tag:$(ELASTIC_VERSION)-SNAPSHOT

# Build images from the latest snapshots on snapshots.elastic.co
from-snapshot:
	$(TEDI) build --asset-set=remote_snapshot --fact=image_tag:$(ELASTIC_VERSION)-SNAPSHOT

# Push the images to the dedicated push endpoint at "push.docker.elastic.co"
push: test
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) push.$(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	echo; echo "Pushing $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG)"; echo; \
	docker push push.$(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	docker rmi push.$(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	)

# Also push the plain named image based on DEFAULT_IMAGE_FLAVOR
# e.g. elasticsearch-full:6.0.0 and elasticsearch:6.0.0 are the same.
	@if [[ -z "$$(docker images -q $(IMAGE_TAG):$(VERSION_TAG))" ]]; then\
	  echo;\
	  echo "I can't push $(IMAGE_TAG):$(VERSION_TAG)";\
	  echo "probably because you didn't build the \"$(DEFAULT_IMAGE_FLAVOR)\" image (check your \$$IMAGE_FLAVORS).";\
	  echo;\
	  echo "Failing here.";\
	  echo;\
	  exit 1;\
        fi

	docker tag $(IMAGE_TAG):$(VERSION_TAG) push.$(IMAGE_TAG):$(VERSION_TAG)
	echo; echo "Pushing $(IMAGE_TAG):$(VERSION_TAG)"; echo;
	docker push push.$(IMAGE_TAG):$(VERSION_TAG)
	docker rmi push.$(IMAGE_TAG):$(VERSION_TAG)

# The tests are written in Python. Make a virtualenv to handle the dependencies.
venv: requirements.txt
	@if [ -z $$PYTHON3 ]; then\
	    PY3_MINOR_VER=`python3 --version 2>&1 | cut -d " " -f 2 | cut -d "." -f 2`;\
	    if (( $$PY3_MINOR_VER < 5 )); then\
		echo "Couldn't find python3 in \$PATH that is >=3.5";\
		echo "Please install python3.5 or later or explicity define the python3 executable name with \$PYTHON3";\
	        echo "Exiting here";\
	        exit 1;\
	    else\
		export PYTHON3="python3.$$PY3_MINOR_VER";\
	    fi;\
	fi;\
	test -d venv || virtualenv --python=$$PYTHON3 venv;\
	pip install -r requirements.txt;\
	touch venv;\
