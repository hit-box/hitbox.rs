.PHONY: blog-sync blog-dev blog-build clean ensure-zola

SHARED_SCSS  = shared/scss
SHARED_FONTS = shared/fonts
BLOG_DIR     = blog
ZOLA_VERSION ?= 0.19.2

# Download Zola if not found in PATH
ensure-zola:
	@which zola > /dev/null 2>&1 || { \
		echo "Downloading Zola $(ZOLA_VERSION)..."; \
		curl -sL "https://github.com/getzola/zola/releases/download/v$(ZOLA_VERSION)/zola-v$(ZOLA_VERSION)-x86_64-unknown-linux-gnu.tar.gz" | tar xz -C /usr/local/bin; \
		echo "Zola $(ZOLA_VERSION) installed"; \
	}

# Copy shared design tokens into blog project before build
blog-sync:
	@mkdir -p $(BLOG_DIR)/sass/shared
	@mkdir -p $(BLOG_DIR)/static/fonts/jetbrains-mono
	@cp $(SHARED_SCSS)/*.scss $(BLOG_DIR)/sass/shared/
	@cp $(SHARED_FONTS)/jetbrains-mono/*.woff2 $(BLOG_DIR)/static/fonts/jetbrains-mono/
	@echo "shared assets synced → blog/"

# Development server with live reload
blog-dev: blog-sync
	cd $(BLOG_DIR) && zola serve

# Production build
blog-build: ensure-zola blog-sync
	cd $(BLOG_DIR) && zola build

# Remove synced shared assets from sub-projects
clean:
	rm -rf $(BLOG_DIR)/sass/shared
	rm -rf $(BLOG_DIR)/static/fonts
	@echo "cleaned synced assets"
