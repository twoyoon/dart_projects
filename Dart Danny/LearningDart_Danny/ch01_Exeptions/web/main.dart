// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.


void main() {
  //This will cause an Unhandled Exception
  try {
    var input = "47B9";
    int i = int.parse(input);
  } on FormatException catch (e) {
    print("Format Exeption: int.parse");
  } on Exception catch (e) {
    print("Unknown exception: $e");
  } catch (e) {
    //No Specific error handles all
    print('Something really unknown');
  } finally {
    print('Ok clean up here');
  }

  //This throws a proper exception
  try{
    properException();
  } on Exception catch (e){
    print("Exception = $e");
  }

  //throws unimplement error
  try{
    throwUnimplemented();
  } catch(e){
    print("$e");
  }

  //out of array range erro
  var lst=[1,2,3,4,5];
  for(int i=0; i<=lst.length;i++)
      print("${lst[i]}");

}

//This is function will throw and exception
//funThrows();
funThrows(){
  throw 'I am throwing a fit and an Exeption';
}

properException() => throw new Exception('Proper Exception');

throwUnimplemented() => throw new UnimplementedError("Implement this Error");

class test{
  String _name;
  set name(String n){
    _name=n;
  }

}