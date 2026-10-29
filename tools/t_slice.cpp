#include "../Engine/src/slicer.hpp"
#include <fstream>
#include <iostream>
#include <sstream>
#include <chrono>
using namespace a1;
int main(int c, char** v){
  std::ifstream f(v[1], std::ios::binary); std::stringstream ss; ss<<f.rdbuf();
  auto P=Project::load(ss.str()); int plate=std::atoi(v[2])-1;
  SliceSettings S; S.brimType=c>4?v[4]:"no_brim"; S.skirtLoops=1;
  auto t0=std::chrono::steady_clock::now();
  auto PS=slicePlate(*P,plate,S,{},nullptr);
  auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-t0).count();
  size_t np=0; for(auto&L:PS.layers) for(auto&i:L.islands) np+=i.paths.size();
  std::cout<<"slice ms "<<ms<<" layers "<<PS.layers.size()<<" paths "<<np<<" maxZ "<<PS.maxZ<<" bbox "<<PS.minX<<","<<PS.minY<<" - "<<PS.maxX<<","<<PS.maxY<<" fils";
  for(int x:PS.filamentsUsed) std::cout<<" "<<x; std::cout<<"\n"; for(auto&w:PS.warnings) std::cout<<"WARN "<<w<<"\n";
  // dump requested layer
  int li=std::atoi(v[3]); std::ofstream o(std::string("/tmp/claude-0/-home-claude/aea00b61-eb65-5fcd-a3e6-866b48ced0d4/scratchpad/shots/layer.json"));
  o<<"{\"colors\":["; for(size_t i=0;i<P->colors.size();++i) o<<(i?",":"")<<"\""<<P->colors[i]<<"\""; o<<"],\"paths\":[";
  bool firstp=true; auto&L=PS.layers[std::min<int>(li,PS.layers.size()-1)];
  for(auto&isl:L.islands) for(auto&tp:isl.paths){ o<<(firstp?"":",")<<"{\"f\":"<<isl.filament<<",\"r\":"<<(int)tp.role<<",\"c\":"<<tp.closed<<",\"w\":"<<tp.width<<",\"p\":["; firstp=false;
    for(size_t k=0;k<tp.pts.size();++k) o<<(k?",":"")<<tp.pts[k].x/kScale<<","<<tp.pts[k].y/kScale; o<<"]}"; }
  o<<"]}";
}
