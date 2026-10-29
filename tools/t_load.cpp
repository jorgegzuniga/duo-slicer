#include "../Engine/src/project.hpp"
#include <fstream>
#include <iostream>
#include <sstream>
#include <chrono>
int main(int c, char** v){
  std::ifstream f(v[1], std::ios::binary); std::stringstream ss; ss<<f.rdbuf();
  auto t0=std::chrono::steady_clock::now();
  auto P=a1::Project::load(ss.str());
  auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-t0).count();
  std::cout<<"load ms "<<ms<<" plates "<<P->plates.size()<<" objects "<<P->objects.size()<<" model "<<P->printerModel<<"\n";
  for(auto& pl:P->plates){ std::cout<<"plate "<<pl.id<<" '"<<pl.name<<"' objs:";
    for(int oi:pl.objects){ auto&o=P->objects[oi]; double mn[3],mx[3]; P->objectBounds(o,o.item,mn,mx);
      std::cout<<" ["<<o.name<<" vols="; for(auto&vv:o.volumes) std::cout<<vv.filament<<"("<<vv.tris.size()/3<<")"; 
      std::cout<<" x "<<mn[0]-pl.ox<<".."<<mx[0]-pl.ox<<" y "<<mn[1]-pl.oy<<".."<<mx[1]-pl.oy<<" z "<<mn[2]<<".."<<mx[2]<<"]"; }
    std::cout<<"\n"; }
}
