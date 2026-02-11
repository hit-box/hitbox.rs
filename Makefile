.PHONY: blog-sync blog-dev blog-build clean ensure-zola

SHARED_SCSS   = shared/scss
SHARED_FONTS  = shared/fonts
SHARED_IMAGES = shared/images
BLOG_DIR      = blog
ZOLA_VERSION ?= 0.22.1
ZOLA_LOCAL   = $(CURDIR)/.bin/zola

# Download exact Zola version into .bin/
ensure-zola:
	@if [ -x .bin/zola ] && .bin/zola --version 2>/dev/null | grep -q "$(ZOLA_VERSION)"; then \
		true; \
	else \
		mkdir -p .bin; \
		echo "Downloading Zola $(ZOLA_VERSION)..."; \
		curl -sL "https://github.com/getzola/zola/releases/download/v$(ZOLA_VERSION)/zola-v$(ZOLA_VERSION)-x86_64-unknown-linux-gnu.tar.gz" | tar xz -C .bin; \
		echo "Zola $(ZOLA_VERSION) installed to .bin/"; \
	fi

# Copy shared design tokens into blog project before build
blog-sync:
	@mkdir -p $(BLOG_DIR)/sass/shared
	@mkdir -p $(BLOG_DIR)/static/fonts/jetbrains-mono
	@mkdir -p $(BLOG_DIR)/static/images
	@cp $(SHARED_SCSS)/*.scss $(BLOG_DIR)/sass/shared/
	@cp $(SHARED_FONTS)/jetbrains-mono/*.woff2 $(BLOG_DIR)/static/fonts/jetbrains-mono/
	@cp $(SHARED_IMAGES)/* $(BLOG_DIR)/static/images/
	@echo "shared assets synced → blog/"

# Development server with live reload
blog-dev: ensure-zola blog-sync
	cd $(BLOG_DIR) && $(ZOLA_LOCAL) serve

# Production build
blog-build: ensure-zola blog-sync
	cd $(BLOG_DIR) && $(ZOLA_LOCAL) build

# Remove synced shared assets from sub-projects
clean:
	rm -rf $(BLOG_DIR)/sass/shared
	rm -rf $(BLOG_DIR)/static/fonts
	rm -rf $(BLOG_DIR)/static/images
	@echo "cleaned synced assets"
