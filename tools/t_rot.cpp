#include "../Engine/include/a1engine.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
static std::string slurp(const char* p){ std::ifstream f(p, std::ios::binary); std::stringstream s; s<<f.rdbuf(); return s.str(); }
int main(int, char** v){
  std::string prof=slurp(v[1]), proj=slurp(v[2]);
  A1Engine* e=a1_create(prof.c_str()); a1_free(a1_open(e,(const uint8_t*)proj.data(),proj.size()));
  auto info=[&](){ char* s=a1_info(e); std::string r=s; a1_free(s); size_t p=r.find("\"name\":\"Layer 4 - cream\""); return r.substr(p,330); };
  // object for plate 4 is index? find via info
  int oi=-1; { char* s=a1_info(e); std::string r=s; a1_free(s); size_t p=r.find("\"name\":\"Layer 4 - cream\""); size_t q=r.rfind("\"index\":",p); oi=std::stoi(r.substr(q+8)); }
  std::cout<<"obj "<<oi<<"\n"<<info()<<"\n";
  a1_rotate(e,oi,2,90); std::cout<<"Z90 "<<info()<<"\n";
  a1_rotate(e,oi,0,90); std::cout<<"X90 "<<info()<<"\n";
  a1_auto_flat(e,oi); std::cout<<"auto "<<info()<<"\n";
  char* s=a1_slice(e,3,"{}",nullptr,nullptr); std::string r=s; a1_free(s); std::cout<<r.substr(0,300)<<"\n";
  uint8_t* d; size_t n; a1_export_project(e,&d,&n); std::cout<<"export bytes "<<n<<"\n"; a1_free(d);
}
