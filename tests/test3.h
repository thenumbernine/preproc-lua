// this fails with replacing the param arg "args"="int type" with the other arg "type"="void"
//  that'll cause "int type" to look like "int void"
#define PNG_FUNCTION(type, args) type functionname args
PNG_FUNCTION(void, (int type));
