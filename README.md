# fluent-plugin-docker_metadata_filter, a plugin for [Fluentd](http://fluentd.org)
[![Circle CI](https://circleci.com/gh/fabric8io/fluent-plugin-docker_metadata_filter.svg?style=svg)](https://circleci.com/gh/fabric8io/fluent-plugin-docker_metadata_filter)
[![Code Climate](https://codeclimate.com/github/fabric8io/fluent-plugin-docker_metadata_filter/badges/gpa.svg)](https://codeclimate.com/github/fabric8io/fluent-plugin-docker_metadata_filter)
[![Test Coverage](https://codeclimate.com/github/fabric8io/fluent-plugin-docker_metadata_filter/badges/coverage.svg)](https://codeclimate.com/github/fabric8io/fluent-plugin-docker_metadata_filter)

## Installation

    gem install fluent-plugin-docker_metadata_filter

## Configuration
```
<source>
  type tail
  path /var/lib/docker/containers/*/*-json.log
  pos_file fluentd-docker.pos
  time_format %Y-%m-%dT%H:%M:%S
  tag docker.*
  format json
  read_from_head true
</source>

<filter docker.var.lib.docker.containers.*.*.log>
  type docker_metadata
</filter>

<match **>
  type stdout
</match>
```

Docker logs in JSON format. Log files are normally in
`/var/lib/docker/containers/*/*-json.log`, depending on what your Docker
data directory is.

Assuming following inputs are coming from a log file:
df14e0d5ae4c07284fa636d739c8fc2e6b52bc344658de7d3f08c36a2e804115-json.log:
```
{
  "log": "2015/05/05 19:54:41 \n",
  "stream": "stderr",
  "time": "2015-05-05T19:54:41.240447294Z"
}
```

Then output becomes as belows
```
{
  "log": "2015/05/05 19:54:41 \n",
  "stream": "stderr",
  "docker": {
    "id": "df14e0d5ae4c07284fa636d739c8fc2e6b52bc344658de7d3f08c36a2e804115",
    "name": "/k8s_fabric8-console-container.efbd6e64_fabric8-console-controller-9knhj_default_8ae2f621-f360-11e4-8d12-54ee7527188d_7ec9aa3e",
    "container_hostname": "fabric8-console-controller-9knhj",
    "image": "fabric8/hawtio-kubernetes:latest",
    "image_id": "b2bd1a24a68356b2f30128e6e28e672c1ef92df0d9ec01ec0c7faea5d77d2303",
    "labels": {}
  }
}
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## Copyright
  Copyright (c) 2015 jimmidyson
