#define X

#if 0
#elif defined(X)	// eval = false, preveval = true
#else
	#error "failed to eval elif true macro"
#endif

#if 0
#if MACRO_NOT_DEFINED(X)	// eval = false, preveval = true ... this will fail to parse
#error "failed to skip unevaluated expression of undefined macro"
#endif
#endif
