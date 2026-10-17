#include "BeatNetBridge.h"
#include "stream.h"
#include <cmath>
#include <cstdio>
int main(int argc,char **argv){
 if(argc!=2)return 2;
 beatnet_model model;if(!model.load(argv[1]))return 3;
 beatnet_stream upstream(model);void *engine=caption_beatnet_create(".build/beatnet/runtime/libcaption_beatnet.dylib",argv[1]);if(!engine)return 4;
 float samples[2205];CaptionBeatEvent events[16];int total=0;
 // Compare every emitted event against upstream for 60 seconds, including a reset.
 for(int run=0;run<2;++run){
  if(run){upstream.reset();caption_beatnet_reset(engine);}
  for(int chunk=0;chunk<300;++chunk){
   for(int i=0;i<2205;++i){double t=(chunk*2205+i)/22050.;double offset=fmod(t,.5);samples[i]=.65*exp(-offset*60)*sin(2*3.141592653589793*100*offset);}
   auto expected=upstream.push(samples,2205);int count=caption_beatnet_process(engine,samples,2205,events,16);
   if(count!=(int)expected.size())return 5;
   for(int i=0;i<count;++i)if(events[i].time!=expected[i].time||events[i].type!=expected[i].type)return 6;
   total+=count;
  }
 }
 caption_beatnet_free(engine);printf("PASS bounded runtime: %d exact upstream beat events across 60s, reset reproduced\n",total);return 0;
}
