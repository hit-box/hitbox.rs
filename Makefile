.PHONY: blog-sync blog-dev blog-build clean ensure-zola og-images

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

# Generate OG images from Zola-rendered HTML (requires chromium)
# Auto-discovers articles with og_image in frontmatter, creates ephemeral
# mirror pages in content/og/, builds, screenshots, then cleans up.
og-images: ensure-zola blog-sync
	@mkdir -p $(BLOG_DIR)/content/og
	@printf '+++\nrender = false\nsort_by = "none"\ngenerate_feeds = false\n+++\n' \
		> $(BLOG_DIR)/content/og/_index.md
	@for d in $(BLOG_DIR)/content/blog/*/; do \
		if grep -q 'og_image' "$$d/index.md" 2>/dev/null; then \
			slug=$$(basename "$$d"); \
			printf '+++\ntitle = "OG"\ntemplate = "og-image.html"\n\n[extra]\nsource = "blog/%s/index.md"\n+++\n' \
				"$$slug" > $(BLOG_DIR)/content/og/$$slug.md; \
		fi; \
	done
	cd $(BLOG_DIR) && $(ZOLA_LOCAL) build
	@mkdir -p $(BLOG_DIR)/static/og
	@for f in $(BLOG_DIR)/public/og/*/index.html; do \
		name=$$(basename $$(dirname "$$f")); \
		echo "Generating OG image: $$name.png"; \
		chromium --headless --disable-gpu \
			--screenshot=$(BLOG_DIR)/static/og/$$name.png \
			--window-size=1200,630 --hide-scrollbars "$$f" 2>/dev/null; \
	done
	@rm -rf $(BLOG_DIR)/content/og
	@echo "OG images generated → $(BLOG_DIR)/static/og/"

# Remove synced shared assets from sub-projects
clean:
	rm -rf $(BLOG_DIR)/sass/shared
	rm -rf $(BLOG_DIR)/static/fonts
	rm -rf $(BLOG_DIR)/static/images
	@echo "cleaned synced assets"
