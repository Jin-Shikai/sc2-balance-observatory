.PHONY: lint test fmt plan apply

lint:
	ruff check ingestion
	terraform -chdir=infra fmt -check -recursive

fmt:
	ruff check --fix ingestion
	terraform -chdir=infra fmt -recursive

test:
	cd ingestion && python -m pytest -q

plan:
	terraform -chdir=infra plan

apply:
	terraform -chdir=infra apply
