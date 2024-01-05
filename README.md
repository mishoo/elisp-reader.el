elisp-reader.el
===============

A custom Lisp reader written in Emacs Lisp. This makes it possible to define
syntax extensions, similar to what one can do in Common Lisp with
`set-macro-character`.

Once loaded, this library will kick in when loading other `.el` files, when
evaluating expressions in a buffer via `C-M-x` or via `M-x eval-region` or when
running commands in the REPL (`M-x ielm`) etc. If there are bugs, they will
most probably render your Emacs session unusable.

It's recommended to byte-compile it before loading, otherwise it's quite slow:

    emacs --batch --eval '(byte-compile-file "elisp-reader.el")'

This isn't a final product. It's rather a request for brainstorming. It proves
that it's possible to implement file-local symbols or a better syntax for
RegExp-s; a customizable reader in general—by just doing everything in Lisp
rather than in C.

See the commentary [inside the file](./elisp-reader.el) for more information.
