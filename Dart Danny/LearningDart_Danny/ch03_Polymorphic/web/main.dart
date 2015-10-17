// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.


void main() {
  var duck1 = new Duck();
  var dave = new Person();
  print(dave.sayQuack());

  print((dave as Duck).swimAway());
  print(dave.novar);
}

abstract class Quackable{
String sayQuack();
}

class Duck implements Quackable{
  var color;
  Duck([this.color='red']);
  Duck.yellow(){this.color='yellow';}

  String sayQuack()=> 'Quack';
  String swimAway()=> "I'm gone, quack!";
}

class Person implements Duck{
  String sayQuack()=>"human_quack";
  noSuchMethod(Invocation invocation){
    print('${invocation.memberName} NOT FOUND!');
    if(invocation.memberName == new Symbol('swimAway'))
      print("I'm not really a duck");
  }
}
