#include <taskflow/taskflow.hpp>
#include <taskflow/algorithm/for_each.hpp>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

struct Workload { const char* name; std::size_t chunks; std::uint32_t iterations; bool irregular; };
static std::uint64_t job(std::size_t id, std::uint32_t iterations, bool irregular) {
  const auto count = irregular ? iterations + static_cast<std::uint32_t>((id * 2654435761ULL) % (iterations + 1ULL)) : iterations;
  std::uint64_t value = id + 1;
  for(std::uint32_t i=0; i<count; ++i) value = value * 1664525ULL + 1013904223ULL + i;
  return value;
}
static std::uint64_t sequential(const Workload& w) {
  std::uint64_t sum=0; for(std::size_t i=0;i<w.chunks;++i) sum+=job(i,w.iterations,w.irregular); return sum;
}
int main(int argc, char** argv) {
  if(argc != 5 && argc != 6) { std::cerr << "usage: taskflow_reference WORKERS SAMPLES WARMUPS BASE_ITERATIONS [WAVES]\n"; return 2; }
  const std::size_t workers=std::stoull(argv[1]), samples=std::stoull(argv[2]), warmups=std::stoull(argv[3]);
  const auto base=static_cast<std::uint32_t>(std::stoul(argv[4]));
  const std::size_t waves=argc==6?std::stoull(argv[5]):1;
  if(!workers || workers>256 || !samples || samples>1000 || warmups>1000 ||
     !base || base>1000000 || !waves || waves>1000) return 2;
  const std::vector<Workload> workloads={{"fine",1024,base,false},{"medium",256,base*8,false},{"coarse",32,base*64,false},{"irregular",256,base*4,true}};
  const std::vector<std::size_t> grains={1,4,8,16,32,64,128,256,512};
  std::cout << "language,phase,sample,workload,arm,workers,batch_size,chunks,elapsed_ns,checksum\n";
  for(const auto& w: workloads) {
    const auto expected=sequential(w);
    for(auto grain: grains) for(std::size_t sample=0;sample<warmups+samples;++sample) for(const std::string arm: {"static","guided"}) {
      const auto start=std::chrono::steady_clock::now();
      std::uint64_t checksum=0;
      {
        tf::Executor executor(workers);
        std::vector<std::uint64_t> values(w.chunks);
        tf::Taskflow flow;
        for(std::size_t wave=0;wave<waves;++wave) {
          tf::Taskflow flow;
          if(arm=="static") flow.for_each_index(std::size_t{0},w.chunks,std::size_t{1},[&](std::size_t id){values[id]=job(id,w.iterations,w.irregular);},tf::StaticPartitioner(grain));
          else flow.for_each_index(std::size_t{0},w.chunks,std::size_t{1},[&](std::size_t id){values[id]=job(id,w.iterations,w.irregular);},tf::GuidedPartitioner(grain));
          executor.run(flow).wait();
          for(auto value:values) checksum+=value;
        }
      }
      const auto ns=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count();
      if(checksum!=expected*waves) return 3;
      std::cout << "taskflow," << (sample<warmups?"warmup":"measure") << ',' << sample << ',' << w.name << ',' << arm << ',' << workers << ',' << grain << ',' << w.chunks*waves << ',' << ns << ',' << checksum << '\n';
    }
  }
}
