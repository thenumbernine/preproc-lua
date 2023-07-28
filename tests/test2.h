// should produce "typedef void (PNGCAPI *png_longjmp_ptr) PNGARG((jmp_buf, int));"
// but sometimes bumps with my prevent-infinite-recursion-expansion and doesn't expand the 'type' arg
#ifndef PNG_FUNCTION
#  define PNG_FUNCTION(type, name, args, attributes) attributes type name args
#endif
PNG_FUNCTION(void, (PNGCAPI *png_longjmp_ptr), PNGARG((jmp_buf, int)), typedef);
