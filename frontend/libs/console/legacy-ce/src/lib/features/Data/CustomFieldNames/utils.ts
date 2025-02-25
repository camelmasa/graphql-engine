import { Driver } from '@/dataSources';
import { getDriverPrefix } from '@/features/DataSource';
import { MetadataTableConfig } from '@/features/hasura-metadata-types';
import pickBy from 'lodash.pickby';
import {
  CustomFieldNamesFormVals,
  GetTablePayloadArgs,
  QualifiedTable,
} from './types';

export const customFieldNamesPlaceholders = (
  tableName: string
): CustomFieldNamesFormVals => ({
  custom_name: `${tableName} (default)`,
  select: `${tableName} (default)`,
  select_by_pk: `${tableName}_by_pk (default)`,
  select_aggregate: `${tableName}_aggregate (default)`,
  select_stream: `${tableName}_stream (default)`,
  insert: `insert_${tableName} (default)`,
  insert_one: `insert_${tableName}_one (default)`,
  update: `update_${tableName} (default)`,
  update_by_pk: `update_by_pk_${tableName} (default)`,
  delete: `delete_${tableName} (default)`,
  delete_by_pk: `delete_by_pk_${tableName} (default)`,
  update_many: `update_many_${tableName} (default)`,
});

export const buildConfigFromFormValues = (
  values: CustomFieldNamesFormVals
): MetadataTableConfig => {
  // we want to only add properties if a value is "truthy"/not empty

  const config: MetadataTableConfig = {};
  // the shape of the form type almost matches the config type
  const { custom_name, ...customRoots } = values;

  if (custom_name) config.custom_name = custom_name;

  const rootsWithValues = pickBy(customRoots, v => v !== '');

  if (Object.keys(rootsWithValues).length > 0) {
    config.custom_root_fields = rootsWithValues;
  }

  return config;
};

export const getTrackTableType = (driver: Driver) => {
  const prefix = getDriverPrefix(driver);
  return `${prefix}_track_table`;
};

export const getQualifiedTable = ({
  driver,
  schema,
  tableName,
}: GetTablePayloadArgs): QualifiedTable => {
  if (driver === 'bigquery') {
    return {
      dataset: schema,
      name: tableName,
    };
  }
  return {
    schema,
    name: tableName,
  };
};

export const query_field_props: (keyof CustomFieldNamesFormVals)[] = [
  'select',
  'select_by_pk',
  'select_aggregate',
  'select_stream',
];
export const mutation_field_props: (keyof CustomFieldNamesFormVals)[] = [
  'insert',
  'insert_one',
  'update',
  'update_by_pk',
  'delete',
  'delete_by_pk',
];

export const initFormValues = (currentConfiguration?: MetadataTableConfig) => ({
  custom_name: currentConfiguration?.custom_name || '',
  select: '',
  select_by_pk: '',
  select_aggregate: '',
  select_stream: '',
  insert: '',
  insert_one: '',
  update: '',
  update_by_pk: '',
  delete: '',
  delete_by_pk: '',
  update_many: '',
  ...(currentConfiguration?.custom_root_fields || {}),
});
