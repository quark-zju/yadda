<?php

final class CelerityYaddaResources extends CelerityResourcesOnDisk {

  public function getName() {
    return 'yadda';
  }

  public function getPathToResources() {
    return $this->joinPath('../assets');
  }

  public function getPathToMap() {
    return $this->joinPath('res/map.php');
  }

  private function joinPath($to_file) {
    return (phutil_get_library_root('phabsummary')).'/'.$to_file;
  }

}
