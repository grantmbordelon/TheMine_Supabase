-- Core message: the one-line headline above the summary bullets on the Present report.
alter table settings
  add column core_message text not null default '';

-- Promote the current first summary bullet to the core message.
update settings
set core_message = summary_bullets ->> 0,
    summary_bullets = summary_bullets - 0
where core_message = '' and jsonb_array_length(summary_bullets) > 0;
