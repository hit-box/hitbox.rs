.PHONY: blog-sync blog-dev blog-build clean

SHARED_SCSS  = shared/scss
SHARED_FONTS = shared/fonts
BLOG_DIR     = blog

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
blog-build: blog-sync
	cd $(BLOG_DIR) && zola build

# Remove synced shared assets from sub-projects
clean:
	rm -rf $(BLOG_DIR)/sass/shared
	rm -rf $(BLOG_DIR)/static/fonts
	@echo "cleaned synced assets"
