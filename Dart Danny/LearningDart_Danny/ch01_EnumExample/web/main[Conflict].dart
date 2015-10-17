// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

enum Direction {North, South, East, West}

void main() {
  Direction dir = Direction.North;
  if(dir==Direction.South)
    print("Direction dir = $dir");

  switch(dir){
    case Direction.South:
      print("Switch test: dir == South");
      break;
    case Direction.North:
      print("Switch test: dir == North");
      break;
    case Direction.East:
      print("Switch test: dir == East");
      break;
    case Direction.West:
      print("Switch test: dir == West");
      break;
    default:
      print("Error!");
  }

}
