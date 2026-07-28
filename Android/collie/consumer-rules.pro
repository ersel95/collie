# Collie ships no reflection and no annotation processing, so consumers need no rules of
# their own. The file exists so the entry points survive aggressive shrinking in a host that
# minifies its debug build.
-keep class com.collie.Collie { *; }
-keep class com.collie.CollieConfiguration { *; }
