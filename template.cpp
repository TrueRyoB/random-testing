#include <bits/stdc++.h>
#include <cassert>
using namespace std;
#define ll long long
template<class T> auto sz(const T& x) { return x.size(); }
auto fmt = [](int val) { return val < 0 ? "." : std::to_string(val); };
mt19937_64 rng(chrono::steady_clock::now().time_since_epoch().count());

int rnd(int l, int r) {
  return uniform_int_distribution<int>(l, r)(rng);
}

void solve() {
  /***
  
  
  ***/
}

int main() {
  int T; cin>>T;
  while(T-->0) solve();
}