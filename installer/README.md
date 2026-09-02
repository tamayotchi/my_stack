# Tamayotchi Stack New

Global Mix archive providing `mix tamayotchi.new`.

```sh
MIX_ENV=prod mix archive.build
mix archive.install --force tamayotchi_stack_new-0.1.0.ez
mix tamayotchi.new my_app
```

The installer derives the target directory and root module from `my_app`, and
always initializes Git. It asks only about Phoenix, SQLite, Kamal, and whether
Kamal should use `kamal-proxy`. GoatCounter is always included with Phoenix.
