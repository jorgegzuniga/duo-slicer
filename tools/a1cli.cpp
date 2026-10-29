// Desktop test harness for the engine: a1cli profiles.json project.3mf plate [options.json] out.gcode.3mf
#include "../Engine/include/a1engine.h"
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
static std::string slurp(const char* p){ std::ifstream f(p, std::ios::binary); std::stringstream s; s<<f.rdbuf(); return s.str(); }
int main(int argc, char** argv){
  if(argc<6){ std::cerr<<"usage: a1cli profiles.json project.3mf plateIndex options.json out.gcode.3mf\n"; return 2; }
  std::string prof=slurp(argv[1]), proj=slurp(argv[2]), opts=argc>4?slurp(argv[4]):"{}";
  A1Engine* e=a1_create(prof.c_str());
  char* r=a1_open(e,(const uint8_t*)proj.data(),proj.size()); std::string rs=r; a1_free(r);
  if(rs.find("\"error\"")!=std::string::npos){ std::cerr<<rs<<"\n"; return 1; }
  char* s=a1_slice(e,std::atoi(argv[3]),opts.c_str(),nullptr,nullptr); std::cout<<s<<"\n"; a1_free(s);
  uint8_t* d; size_t n; if(a1_sliced_file(e,&d,&n)==0){ std::ofstream o(argv[5],std::ios::binary); o.write((const char*)d,n); a1_free(d); }
  a1_destroy(e); return 0;
}
