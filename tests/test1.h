// matches the lua.h header
// should cause error "double" if it works
#define LUA_FLOAT_FLOAT 1
#define LUA_FLOAT_DOUBLE 2
#define LUA_FLOAT_LONGDOUBLE 3
#define LUA_FLOAT_DEFAULT LUA_FLOAT_DOUBLE
#define LUA_FLOAT_TYPE LUA_FLOAT_DEFAULT
#if LUA_FLOAT_TYPE == LUA_FLOAT_FLOAT
#error "float"
#elif LUA_FLOAT_TYPE == LUA_FLOAT_DOUBLE
#error "double"
#elif LUA_FLOAT_TYPE == LUA_FLOAT_LONGDOUBLE
#error "longdouble"
#else
#error "unknown"
#endif
#error "error"
