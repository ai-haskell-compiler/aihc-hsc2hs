module ConstStrings where
#include "layout.h"
a = #{const_str SAMPLE_TEXT}
b = #{const_str ESCAPED_TEXT}
c = #{const_str BINARY_TEXT}
d = #{const_str EMPTY_TEXT}
e = #{const_str TERMINATED_TEXT}
f = #{const_str "literal " "joined"}
g = (#const_str SAMPLE_TEXT)
#if SAMPLE_NUMBER == 42
h = #{const_str "active"}
#else
h = #{const_str "inactive"}
#endif
i = #{const_str ("multi "
                 "line")}
