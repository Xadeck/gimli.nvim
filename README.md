Gimli is a plugin for my workflow with the [neovim](http://neovim.io/) editor and the [Bazel](http://bazel.io/) build system.

1.	In one terminal, I run a continuous build with [`ibazel`](https://github.com/bazelbuild/bazel-watcher).  
2.	In another terminal, I edit code with `nvim`.
3.	Whenever I save file, `ibazel` automatically re-runs if needed
4.	When there is a compilation error, I can jump to it directly in `nvim`.

The last point is what this plugin helps with. It parses the build events published by Bazel and populates [Neovim's quick fix](https://neovim.io/doc/user/quickfix.html) list with errors.

Requirements
------------

Add the following to your `.bazelrc`:

```
common --build_event_json_file=.build_event.json
```

This instructs Bazel - when compiling or running tests - to publish build events to a `.build_events.json` file at the top of the Bazel workspace. The build events contains the output of compilation command, from which errors can be found. You probably want to add this file to your `.gitignore` if your workspace is version-controlled.

Install [jq](https://jqlang.org/), the lightweight and flexible command-line JSON processor.

Installation
------------

gimli.nvim supports all the usual plugin managers:

<details>
  <summary>lazy.nvim</summary>

```lua
return {
        'Xadeck/gimli.nvim',
        version = '*',
}
```
    
For a more thorough configuration involving lazy-loading, see [Lazy loading with lazy.nvim](doc/recipes.md#lazy-loading-with-lazynvim).

</details>

Usage
-----

In Neovim, just run the `:Gimli` command. This will replace the quickfix list with errors found from the latest Bazel build events, open the quickfix window, and jump to the first error.
