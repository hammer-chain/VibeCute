#include "BeatNetBridge.h"
#include "features.h"
#include "model.h"
#include "particle_filter.h"
#include <memory>
struct Engine {
 beatnet_model model;
 std::unique_ptr<feature_stream> features;
 beatnet_lstm_state lstm;
 particle_filter_cascade pf;
 std::vector<float> scratch;
 Engine():pf(50,1){}
 void reset(){features->reset();lstm.reset();pf=particle_filter_cascade(50,1);scratch.clear();}
};
extern "C" {
void *bn_create(const char *weights){try{auto e=std::make_unique<Engine>();if(!e->model.load(weights))return nullptr;e->features=std::make_unique<feature_stream>(e->model);e->lstm.init(e->model.num_layers,e->model.num_cells);return e.release();}catch(...){return nullptr;}}
void bn_free(void *p){delete static_cast<Engine *>(p);}
void bn_reset(void *p){static_cast<Engine *>(p)->reset();}
int bn_process(void *p,const float *samples,int count,CaptionBeatEvent *events,int capacity){
 try {
  auto &e=*static_cast<Engine *>(p);e.scratch.clear();auto n=e.features->push(samples,count,e.scratch);
  if(n<=0)return 0;
  auto acts=e.model.infer_stream(e.scratch.data(),n,e.lstm);auto &path=e.pf.process(acts.data(),n);
  int total=(int)path.size()-1; if(total>capacity)return -1;
  for(int i=0;i<total;++i)events[i]={path[i+1].time,path[i+1].type};
  // The filter only references path.back(): retain this phase anchor, not all history.
  auto last=e.pf.path.back();e.pf.path.assign(1,last);
  return total;
 }catch(...){return -1;}
}
}
