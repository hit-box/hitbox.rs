# hitbox.rs

Monorepo for the [Hitbox](https://github.com/hit-box/hitbox) project websites.

| Subdomain | Tool | Status |
|-----------|------|--------|
| `blog.hitbox.rs` | Zola | Active |
| `hitbox.rs` | TBD | Planned |
| `docs.hitbox.rs` | mdbook | Planned |

## Structure

```
shared/                 Shared design tokens (SCSS, fonts, images)
blog/                   Zola blog (blog.hitbox.rs)
  templates/            Tera templates (including og-image.html)
  content/blog/         Blog articles
  static/og/            Generated OG images (committed)
  sass/                 Blog-specific styles + synced shared SCSS
site/                   Landing page (hitbox.rs) — planned
docs/                   Documentation (docs.hitbox.rs) — planned
```

Shared SCSS and fonts from `shared/` are copied into sub-projects at build time
via `make blog-sync`. Each sub-project stays self-contained after the copy.

## Development

The Makefile auto-downloads the pinned Zola version (0.22.1) to `.bin/` — no
manual installation needed.

```sh
# Start blog dev server with live reload
make blog-dev

# Production build
make blog-build

# Clean synced shared assets
make clean
```

## Deployment

The blog is deployed on **Cloudflare Workers** at `blog.hitbox.rs`.

```sh
npx wrangler deploy
```

Configuration is in `wrangler.toml` at the repo root.

## OG Images

OG images are generated from a Zola template (`blog/templates/og-image.html`)
and headless Chromium. The template pulls article metadata (title, tags, reading
time) directly from Zola — no external scripts.

```sh
# Requires chromium
make og-images
```

This auto-discovers all articles with `og_image` in their frontmatter, renders
each one as a 1200x630 HTML page via Zola, screenshots it, and saves the PNG to
`blog/static/og/`. The generated PNGs are committed to the repo since Cloudflare's
build environment doesn't have Chromium.

To add an OG image to a new article, add to its frontmatter:

```toml
[extra]
og_image = "og/your-article-slug.png"
og_highlight = "Word"  # optional — highlighted in accent color
```

Pages without a custom `og_image` use the default hitbox logo.

## License

MIT
