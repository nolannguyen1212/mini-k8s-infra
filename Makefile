build-postgres:
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/platform/postgres

build-miniflux:
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/miniflux
	