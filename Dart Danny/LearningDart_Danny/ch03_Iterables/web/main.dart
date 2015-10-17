// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.



void main() {
  var digits = new Iterable.generate(10,(i)=>i);
  for(var i in digits){
    print(i);
  }
  digits.forEach((i)=>print("foreach: $i"));


}
