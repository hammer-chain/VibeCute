#include "BeatNetBridge.h"
#include <dlfcn.h>
#include <stdlib.h>
typedef struct {
 void *library, *engine;
 void *(*create)(const char *);
 void (*destroy)(void *);
 void (*reset)(void *);
 int (*process)(void *, const float *, int, CaptionBeatEvent *, int);
} Bridge;
void *caption_beatnet_create(const char *library, const char *weights) {
 Bridge *b=calloc(1,sizeof(Bridge)); if(!b) return NULL;
 b->library=dlopen(library,RTLD_NOW|RTLD_LOCAL); if(!b->library){free(b);return NULL;}
 b->create=dlsym(b->library,"bn_create"); b->destroy=dlsym(b->library,"bn_free");
 b->reset=dlsym(b->library,"bn_reset"); b->process=dlsym(b->library,"bn_process");
 if(!b->create||!b->destroy||!b->reset||!b->process){dlclose(b->library);free(b);return NULL;}
 b->engine=b->create(weights); if(!b->engine){dlclose(b->library);free(b);return NULL;}
 return b;
}
void caption_beatnet_free(void *p){ if(!p)return; Bridge *b=p;b->destroy(b->engine);dlclose(b->library);free(b); }
void caption_beatnet_reset(void *p){if(p){Bridge *b=p;b->reset(b->engine);}}
int caption_beatnet_process(void *p,const float *samples,int count,CaptionBeatEvent *events,int capacity){if(!p)return -1;Bridge *b=p;return b->process(b->engine,samples,count,events,capacity);}
