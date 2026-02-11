# hitbox.rs

Monorepo for the [Hitbox](https://github.com/hit-box/hitbox) project websites.

| Subdomain | Tool | Status |
|-----------|------|--------|
| `blog.hitbox.rs` | Zola | Active |
| `hitbox.rs` | TBD | Planned |
| `docs.hitbox.rs` | mdbook | Planned |

## Structure

```
shared/     Shared design tokens (SCSS, fonts)
blog/       Zola blog (blog.hitbox.rs)
site/       Landing page (hitbox.rs) — planned
docs/       Documentation (docs.hitbox.rs) — planned
```

## Development

Requires [Zola](https://www.getzola.org/documentation/getting-started/installation/).

```sh
# Start blog dev server with live reload
make blog-dev

# Production build
make blog-build

# Clean synced shared assets
make clean
```

## License

MIT
