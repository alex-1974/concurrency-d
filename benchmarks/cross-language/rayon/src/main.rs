use rayon::prelude::*;
use std::time::Instant;

struct Workload { name: &'static str, chunks: usize, iterations: u32, irregular: bool }
fn job(id: usize, iterations: u32, irregular: bool) -> u64 {
    let count = if irregular { iterations + ((id as u64 * 2654435761) % (iterations as u64 + 1)) as u32 } else { iterations };
    let mut value = id as u64 + 1;
    for i in 0..count { value = value.wrapping_mul(1664525).wrapping_add(1013904223).wrapping_add(i as u64); }
    value
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len()!=5 && a.len()!=6 { eprintln!("usage: rayon-reference WORKERS SAMPLES WARMUPS BASE_ITERATIONS [WAVES]"); std::process::exit(2); }
    let workers:usize=a[1].parse().unwrap(); let samples:usize=a[2].parse().unwrap(); let warmups:usize=a[3].parse().unwrap(); let base:u32=a[4].parse().unwrap();
    let waves:usize=if a.len()==6 {a[5].parse().unwrap()} else {1};
    if workers==0 || workers>256 || samples==0 || samples>1000 || warmups>1000 || base==0 || base>1_000_000 || waves==0 || waves>1000 { std::process::exit(2); }
    let workloads=[Workload{name:"fine",chunks:1024,iterations:base,irregular:false},Workload{name:"medium",chunks:256,iterations:base*8,irregular:false},Workload{name:"coarse",chunks:32,iterations:base*64,irregular:false},Workload{name:"irregular",chunks:256,iterations:base*4,irregular:true}];
    let grains=[1usize,4,8,16,32,64,128,256,512];
    println!("language,phase,sample,workload,arm,workers,batch_size,chunks,elapsed_ns,checksum");
    for w in workloads {
        let expected:u64=(0..w.chunks).map(|id|job(id,w.iterations,w.irregular)).sum();
        for grain in grains { for sample in 0..warmups+samples { for arm in ["min_len","max_len"] {
            let start=Instant::now();
            let pool=rayon::ThreadPoolBuilder::new().num_threads(workers).build().unwrap();
            let mut values=vec![0u64;w.chunks]; let mut checksum=0u64;
            for _ in 0..waves {
                pool.install(|| {
                    let iter=(0..w.chunks).into_par_iter();
                    if arm=="min_len" { iter.with_min_len(grain).zip(values.par_iter_mut()).for_each(|(id,value)|*value=job(id,w.iterations,w.irregular)); }
                    else { iter.with_max_len(grain).zip(values.par_iter_mut()).for_each(|(id,value)|*value=job(id,w.iterations,w.irregular)); }
                });
                checksum=checksum.wrapping_add(values.iter().sum::<u64>());
            }
            drop(pool);
            let ns=start.elapsed().as_nanos();
            if checksum!=expected.wrapping_mul(waves as u64) { std::process::exit(3); }
            println!("rayon,{},{},{},{},{},{},{},{},{}",if sample<warmups{"warmup"}else{"measure"},sample,w.name,arm,workers,grain,w.chunks*waves,ns,checksum);
        }}}
    }
}
