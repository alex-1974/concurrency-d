module negative_private_owner;
import concurrency : Executor;
void forbidden(Executor executor) { auto owner = executor._impl; }
void main() {}
