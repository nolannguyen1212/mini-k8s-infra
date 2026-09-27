.PHONY: cluster build-postgres build-miniflux

cluster:
	sh scripts/cluster-setup.sh

build-postgres:
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/platform/postgres

build-miniflux:
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/miniflux
	