" --- Essential Vim Settings ---
set number             " Show line numbers
set syntax=on          " Enable syntax highlighting
set expandtab          " Use spaces instead of tabs
set tabstop=4          " 1 tab = 4 spaces
set shiftwidth=4       " Indent by 4 spaces

" --- Comment Shortcuts (Adds a space) ---
" To comment: Press Ctrl + /
nnoremap <C-_> I# <Esc>
vnoremap <C-_> <Esc>:<C-u>'<,'>s/^/# /<CR>

" --- Uncomment Shortcuts ---
" To uncomment: Press \ then u
nnoremap <Leader>u :s/^#\s\?//<CR>
vnoremap <Leader>u :s/^#\s\?//<CR>
