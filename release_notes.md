# Release Notes

## 2.9.4
As of this release, the 'de_dot' functionality is depricated and will be removed in future releases. 
Ref: https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter/issues/320

## v2.1.4
The use of `use_journal` is **DEPRECATED**.  If this setting is not present, the plugin will
attempt to figure out the source of the metadata fields from the following:
- If `lookup_from_k8s_field true` (the default) and the following fields are present in the record:
`docker.container_id`, `kubernetes.namespace_name`, `kubernetes.pod_name`, `kubernetes.container_name`,
then the plugin will use those values as the source to use to lookup the metadata
- If `use_journal true`, or `use_journal` is unset, and the fields `CONTAINER_NAME` and `CONTAINER_ID_FULL` are present in the record,
then the plugin will parse those values using `container_name_to_kubernetes_regexp` and use those as the source to lookup the metadata
- Otherwise, if the tag matches `tag_to_kubernetes_name_regexp`, the plugin will parse the tag and use those values to
lookup the metdata

## v2.1.x

As of the release 2.1.x of this plugin, it no longer supports parsing the source message into JSON and attaching it to the
payload.  The following configuration options are removed:

* `merge_json_log`
* `preserve_json_log`

One way of preserving JSON logs can be through the [parser plugin](https://docs.fluentd.org/filter/parser).
It can parsed with the parser plugin like this:

```
<filter kubernetes.**>
  @type parser
  key_name log
  <parse>
    @type json
    json_parser json
  </parse>
  replace_invalid_sequence true
  reserve_data true # this preserves unparsable log lines
  emit_invalid_record_to_error false # In case of unparsable log lines keep the error log clean
  reserve_time # the time was already parsed in the source, we don't want to overwrite it with current time.
</filter>
```
