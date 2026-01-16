.PHONY: all install install-dev build clean test coverage lint format check help

PYTHON := python3
PIP := pip3

all: check test

help:
	@echo "RAT - Remote Access Tool"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install      Install package"
	@echo "  install-dev  Install package with dev dependencies"
	@echo "  build        Build distribution packages"
	@echo "  clean        Remove build artifacts and cache"
	@echo "  test         Run tests"
	@echo "  coverage     Run tests with coverage report"
	@echo "  lint         Run pylint"
	@echo "  format       Format code with black"
	@echo "  check        Run format check and lint"
	@echo "  help         Show this help message"

install:
	$(PIP) install -e .

install-dev:
	$(PIP) install -e ".[dev]"
	$(PIP) install pytest pytest-cov black pylint

build:
	$(PYTHON) -m build

clean:
	rm -rf build/
	rm -rf dist/
	rm -rf *.egg-info/
	rm -rf rat/*.egg-info/
	rm -rf .pytest_cache/
	rm -rf .coverage
	rm -rf htmlcov/
	rm -rf __pycache__/
	rm -rf rat/__pycache__/
	rm -rf tests/__pycache__/
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

test:
	pytest tests/ -v

coverage:
	pytest tests/ -v --cov=rat --cov-report=term-missing --cov-report=html --cov-fail-under=95

lint:
	pylint rat/

format:
	black rat/ tests/ --line-length 100

check: format-check lint

format-check:
	black rat/ tests/ --check --line-length 100
