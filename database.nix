{
  runCommand,
  sqlite-utils,
}:
runCommand "readingList.db"
  {
    nativeBuildInputs = [ sqlite-utils ];
  }
  ''
    cp ${./readingList.csv} readingList.csv
    bash ${./run.sh} build
    mv readingList.db "$out"
  ''
