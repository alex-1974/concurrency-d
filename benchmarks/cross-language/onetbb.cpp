#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_for.h>
#include <oneapi/tbb/partitioner.h>
#include <oneapi/tbb/task_arena.h>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

struct Workload { const char* name; std::size_t chunks; std::uint32_t iterations; bool irregular; };
static std::uint64_t job(std::size_t id, std::uint32_t iterations, bool irregular) {
  const auto count=irregular?iterations+static_cast<std::uint32_t>((id*2654435761ULL)%(iterations+1ULL)):iterations;
  std::uint64_t value=id+1;
  for(std::uint32_t i=0;i<count;++i) value=value*1664525ULL+1013904223ULL+i;
  return value;
}
static std::uint64_t sequential(const Workload& w) {
  std::uint64_t sum=0; for(std::size_t i=0;i<w.chunks;++i) sum+=job(i,w.iterations,w.irregular); return sum;
}
int main(int argc,char** argv) {
  if(argc!=5 && argc!=6){std::cerr<<"usage: onetbb_reference WORKERS SAMPLES WARMUPS BASE_ITERATIONS [WAVES]\n";return 2;}
  const int workers=std::stoi(argv[1]); const std::size_t samples=std::stoull(argv[2]),warmups=std::stoull(argv[3]);
  const auto base=static_cast<std::uint32_t>(std::stoul(argv[4]));
  const std::size_t waves=argc==6?std::stoull(argv[5]):1;
  if(workers<1||workers>256||!samples||samples>1000||warmups>1000||!base||base>1000000||!waves||waves>1000)return 2;
  const std::vector<Workload> workloads={{"fine",1024,base,false},{"medium",256,base*8,false},{"coarse",32,base*64,false},{"irregular",256,base*4,true}};
  const std::vector<std::size_t> grains={1,4,8,16,32,64,128,256,512};
  std::cout<<"language,phase,sample,workload,arm,workers,batch_size,chunks,elapsed_ns,checksum\n";
  for(const auto& w:workloads){const auto expected=sequential(w);
    for(auto grain:grains)for(std::size_t sample=0;sample<warmups+samples;++sample)for(const std::string arm:{"simple","auto"}){
      const auto start=std::chrono::steady_clock::now(); std::uint64_t checksum=0;
      {
        std::vector<std::uint64_t> values(w.chunks);
        oneapi::tbb::task_arena arena(workers);
        arena.execute([&]{
          auto body=[&](const oneapi::tbb::blocked_range<std::size_t>& r){for(auto id=r.begin();id!=r.end();++id)values[id]=job(id,w.iterations,w.irregular);};
          for(std::size_t wave=0;wave<waves;++wave) {
            if(arm=="simple") oneapi::tbb::parallel_for(oneapi::tbb::blocked_range<std::size_t>(0,w.chunks,grain),body,oneapi::tbb::simple_partitioner{});
            else oneapi::tbb::parallel_for(oneapi::tbb::blocked_range<std::size_t>(0,w.chunks,grain),body,oneapi::tbb::auto_partitioner{});
            for(auto v:values)checksum+=v;
          }
        });
      }
      const auto ns=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count();
      if(checksum!=expected*waves)return 3;
      std::cout<<"onetbb,"<<(sample<warmups?"warmup":"measure")<<','<<sample<<','<<w.name<<','<<arm<<','<<workers<<','<<grain<<','<<w.chunks*waves<<','<<ns<<','<<checksum<<'\n';
    }
  }
}
