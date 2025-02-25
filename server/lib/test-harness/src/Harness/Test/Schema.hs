{-# LANGUAGE QuasiQuotes #-}

-- | Common interface for setup/teardown for all backends - schema and data
module Harness.Test.Schema
  ( Table (..),
    table,
    Reference (..),
    reference,
    Column (..),
    ScalarType (..),
    defaultSerialType,
    ScalarValue (..),
    WKT (..),
    formatTableQualifier,
    TableQualifier (..),
    Constraint (..),
    UniqueIndex (..),
    BackendScalarType (..),
    BackendScalarValue (..),
    BackendScalarValueType (..),
    ManualRelationship (..),
    SchemaName (..),
    resolveTableSchema,
    resolveReferenceSchema,
    quotedValue,
    unquotedValue,
    backendScalarValue,
    column,
    columnNull,
    defaultBackendScalarType,
    getBackendScalarType,
    defaultBackendScalarValue,
    formatBackendScalarValueType,
    parseUTCTimeOrError,
    trackTable,
    untrackTable,
    mkTableField,
    trackObjectRelationships,
    trackArrayRelationships,
    untrackRelationships,
    mkObjectRelationshipName,
    mkArrayRelationshipName,
    getSchemaName,
    trackFunction,
    untrackFunction,
    trackComputedField,
    untrackComputedField,
    runSQL,
    addSource,
  )
where

import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Time (UTCTime, defaultTimeLocale)
import Data.Time.Format (parseTimeOrError)
import Data.Vector qualified as V
import Harness.Exceptions
import Harness.GraphqlEngine qualified as GraphqlEngine
import Harness.Quoter.Yaml (interpolateYaml, yaml)
import Harness.Test.BackendType (BackendTypeConfig)
import Harness.Test.BackendType qualified as BackendType
import Harness.Test.SchemaName
import Harness.TestEnvironment (TestEnvironment (..), getBackendTypeConfig)
import Hasura.Prelude
import Safe (lastMay)

-- | Generic type to use to specify schema tables for all backends.
-- Usually a list of these make up a "schema" to pass to the respective
-- @Harness.Backend.<Backend>.{setup,teardown}@ functions
--
-- NOTE: There is neither a type-level check to assert that the length of
-- tableColumns matches the length of each row in tableData, nor that the
-- tablePrimaryKey only contains names of columns already in tableColumns or
-- that tableReferences are valid references to other Tables. Test author will
-- need to be just a bit careful while constructing Tables.
data Table = Table
  { tableName :: Text,
    -- | Columns that are references (foreign keys) should be null-able
    tableColumns :: [Column],
    tablePrimaryKey :: [Text],
    tableReferences :: [Reference],
    tableManualRelationships :: [Reference],
    tableData :: [[ScalarValue]],
    tableConstraints :: [Constraint],
    tableUniqueIndexes :: [UniqueIndex],
    tableQualifiers :: [TableQualifier]
  }
  deriving (Show, Eq)

-- | Used to qualify a tracked table by schema (and additionally by GCP projectId, in the case
-- of BigQuery)
newtype TableQualifier = TableQualifier Text
  deriving (Show, Eq)

formatTableQualifier :: TableQualifier -> Text
formatTableQualifier (TableQualifier t) = t

data Constraint = UniqueConstraintColumns [Text] | CheckConstraintExpression Text
  deriving (Show, Eq)

data UniqueIndex = UniqueIndexColumns [Text] | UniqueIndexExpression Text
  deriving (Show, Eq)

-- | Create a table from just a name.
-- Use record updates to modify the result.
table :: Text -> Table
table tableName =
  Table
    { tableName = tableName,
      tableColumns = [],
      tablePrimaryKey = [],
      tableReferences = [],
      tableManualRelationships = [],
      tableData = [],
      tableConstraints = [],
      tableUniqueIndexes = [],
      tableQualifiers = []
    }

-- | Foreign keys for backends that support it.
data Reference = Reference
  { referenceLocalColumn :: Text,
    referenceTargetTable :: Text,
    referenceTargetColumn :: Text,
    referenceTargetQualifiers :: [Text]
  }
  deriving (Show, Eq)

reference :: Text -> Text -> Text -> Reference
reference localColumn targetTable targetColumn =
  Reference
    { referenceLocalColumn = localColumn,
      referenceTargetTable = targetTable,
      referenceTargetColumn = targetColumn,
      referenceTargetQualifiers = mempty
    }

-- | Type representing manual relationship between tables. This is
-- only used for BigQuery backend currently where additional
-- relationships has to be manually specified.
data ManualRelationship = ManualRelationship
  { relSourceTable :: Text,
    relTargetTable :: Text,
    relSourceColumn :: Text,
    relTargetColumn :: Text
  }
  deriving (Show, Eq)

-- | Generic type to construct columns for all backends
data Column = Column
  { columnName :: Text,
    columnType :: ScalarType,
    columnNullable :: Bool,
    columnDefault :: Maybe Text
  }
  deriving (Show, Eq)

-- | Generic type to represent ScalarType for multiple backends. This
-- type can be used to encapsulate the column types for different
-- backends by providing explicit name of the datatype. This provides
-- flexibility and scalability which is difficult to achieve by just
-- extending ScalarType.
--
-- To give a concrete usecase, right now we have 'ScalarType' with
-- value 'TUTCTime'. This is treated as TIMESTAMP for Citus and
-- DATETIME for MSSQL server. There might be usecases where you want
-- your table column to treat it as TIMESTAMP for Citus and
-- <https://docs.microsoft.com/en-us/sql/t-sql/data-types/datetime2-transact-sql?redirectedfrom=MSDN&view=sql-server-ver15
-- DATETIME2> for MSSQL server. BackendScalarType makes such use case
-- very simple to achive instead of making you define a new sum type
-- and handling it.
data BackendScalarType = BackendScalarType
  { bstMysql :: Maybe Text,
    bstCitus :: Maybe Text,
    bstCockroach :: Maybe Text,
    bstPostgres :: Maybe Text,
    bstBigQuery :: Maybe Text,
    bstMssql :: Maybe Text,
    bstSqlite :: Maybe Text
  }
  deriving (Show, Eq)

-- | Default value for 'BackendScalarType' initialized with 'Nothing'
-- for all the fields.
defaultBackendScalarType :: BackendScalarType
defaultBackendScalarType =
  BackendScalarType
    { bstMysql = Nothing,
      bstCitus = Nothing,
      bstCockroach = Nothing,
      bstMssql = Nothing,
      bstPostgres = Nothing,
      bstBigQuery = Nothing,
      bstSqlite = Nothing
    }

-- | Access specific backend scalar type out of 'BackendScalarType'
getBackendScalarType :: BackendScalarType -> (BackendScalarType -> Maybe Text) -> Text
getBackendScalarType bst fn =
  case fn bst of
    Just scalarType -> scalarType
    Nothing -> error $ "getBackendScalarType: BackendScalarType is Nothing, passed " <> show bst

-- | This type represents how the serialization of a value should
-- happen for a particular item. 'Quoted' text indicates that the text
-- will be enclosed with double quotes whereas 'Unqouted' text will have
-- none.
--
-- Usually, texts (or strings) should be represented as quoted and
-- numbers might not require any quotes. Although, consult the
-- particular database backend for the exact behavior. This type has
-- been introduced to allow flexibility while construting values for
-- the columns.
data BackendScalarValueType = Quoted Text | Unquoted Text deriving (Show, Eq)

quotedValue :: Text -> Maybe BackendScalarValueType
quotedValue = Just . Quoted

unquotedValue :: Text -> Maybe BackendScalarValueType
unquotedValue = Just . Unquoted

formatBackendScalarValueType :: BackendScalarValueType -> Text
formatBackendScalarValueType (Quoted text) = "'" <> text <> "'"
formatBackendScalarValueType (Unquoted text) = text

-- | Generic type to represent ScalarValue for multiple backends. This
-- type can be used to encapsulate the column values for different
-- backends by providing explicit data for individual backend. This provides
-- flexibility and scalability which is difficult to achieve by just
-- extending ScalarValue.
--
-- To give a concrete usecase, right now we have timestamp column for
-- out database. Depending on the database, the value can be
-- different. For postgres backend, we use 2017-09-21T09:39:44 to
-- represent timestamp. But we would want to use 2017-09-21T09:39:44Z
-- for Microsoft's SQL server backend. This type provides flexibility
-- to provide such options.
data BackendScalarValue = BackendScalarValue
  { bsvMysql :: Maybe BackendScalarValueType,
    bsvCitus :: Maybe BackendScalarValueType,
    bsvCockroach :: Maybe BackendScalarValueType,
    bsvPostgres :: Maybe BackendScalarValueType,
    bsvBigQuery :: Maybe BackendScalarValueType,
    bsvMssql :: Maybe BackendScalarValueType,
    bsvSqlite :: Maybe BackendScalarValueType
  }
  deriving (Show, Eq)

-- | Default value for 'BackendScalarValue' initialized with 'Nothing'
-- for all the fields.
defaultBackendScalarValue :: BackendScalarValue
defaultBackendScalarValue =
  BackendScalarValue
    { bsvMysql = Nothing,
      bsvCitus = Nothing,
      bsvCockroach = Nothing,
      bsvPostgres = Nothing,
      bsvBigQuery = Nothing,
      bsvMssql = Nothing,
      bsvSqlite = Nothing
    }

-- | Generic scalar type for all backends, for simplicity.
-- Ideally, we would be wiring in @'Backend@ specific scalar types here to make
-- sure all backend-specific scalar types are also covered by tests, perhaps in
-- a future iteration.
data ScalarType
  = TInt
  | TStr
  | TUTCTime
  | TBool
  | TGeography
  | TCustomType BackendScalarType
  deriving (Show, Eq)

-- | Generic scalar value type for all backends, that should directly correspond
-- to 'ScalarType'
data ScalarValue
  = VInt Int
  | VStr Text
  | VUTCTime UTCTime
  | VBool Bool
  | VGeography WKT
  | VNull
  | VCustomValue BackendScalarValue
  deriving (Show, Eq)

-- | Describe Geography values using the WKT representation
-- https://en.wikipedia.org/wiki/Well-known_text_representation_of_geometry
-- https://cloud.google.com/bigquery/docs/geospatial-data#loading_wkt_or_wkb_data
newtype WKT = WKT Text
  deriving (Eq, Show, IsString)

backendScalarValue :: BackendScalarValue -> (BackendScalarValue -> Maybe BackendScalarValueType) -> BackendScalarValueType
backendScalarValue bsv fn = case fn bsv of
  Nothing -> error $ "backendScalarValue: Retrieved value is Nothing, passed " <> show bsv
  Just scalarValue -> scalarValue

defaultSerialType :: ScalarType
defaultSerialType =
  TCustomType $
    defaultBackendScalarType
      { bstMysql = Nothing,
        bstMssql = Just "INT IDENTITY(1,1)",
        bstCitus = Just "SERIAL",
        -- cockroachdb's serial behaves differently than postgresql's serial:
        -- https://www.cockroachlabs.com/docs/v22.1/serial
        bstCockroach = Just "INT4 GENERATED BY DEFAULT AS IDENTITY",
        bstPostgres = Just "SERIAL",
        bstBigQuery = Nothing
      }

-- | Helper function to construct 'Column's with common defaults
column :: Text -> ScalarType -> Column
column name typ = Column name typ False Nothing

-- | Helper function to construct 'Column's that are null-able
columnNull :: Text -> ScalarType -> Column
columnNull name typ = Column name typ True Nothing

-- | Helper to construct UTCTime using @%F %T@ format. For e.g. @YYYY-MM-DD HH:MM:SS@
parseUTCTimeOrError :: String -> ScalarValue
parseUTCTimeOrError = VUTCTime . parseTimeOrError True defaultTimeLocale "%F %T"

-- | we assume we are using the default schema unless a table tells us
-- otherwise
-- when multiple qualifiers are passed, we assume the last one is the schema
resolveTableSchema :: TestEnvironment -> Table -> SchemaName
resolveTableSchema testEnv tbl =
  case resolveReferenceSchema (coerce $ tableQualifiers tbl) of
    Nothing -> getSchemaName testEnv
    Just schemaName -> schemaName

-- | when given a list of qualifiers, we assume that the schema is the last one
-- io Postgres, it'll be the only item
-- in BigQuery, it could be ['project','schema']
resolveReferenceSchema :: [Text] -> Maybe SchemaName
resolveReferenceSchema qualifiers =
  case lastMay qualifiers of
    Nothing -> Nothing
    Just schemaName -> Just (SchemaName schemaName)

-- | Native Backend track table
--
-- Data Connector backends expect an @[String]@ for the table name.
trackTable :: HasCallStack => String -> Table -> TestEnvironment -> IO ()
trackTable source tbl@(Table {tableName}) testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
      schema = resolveTableSchema testEnvironment tbl
      requestType = backendType <> "_track_table"
  GraphqlEngine.postMetadata_
    testEnvironment
    [yaml|
      type: *requestType
      args:
        source: *source
        table:
          schema: *schema
          name: *tableName
    |]

-- | Native Backend track table
--
-- Data Connector backends expect an @[String]@ for the table name.
untrackTable :: HasCallStack => String -> Table -> TestEnvironment -> IO ()
untrackTable source Table {tableName} testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
      schema = getSchemaName testEnvironment
      requestType = backendType <> "_untrack_table"
  GraphqlEngine.postMetadata_
    testEnvironment
    [yaml|
type: *requestType
args:
  source: *source
  table:
    schema: *schema
    name: *tableName
|]

trackFunction :: HasCallStack => String -> String -> TestEnvironment -> IO ()
trackFunction source functionName testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
      schema = getSchemaName testEnvironment
      requestType = backendType <> "_track_function"
  GraphqlEngine.postMetadata_
    testEnvironment
    [yaml|
type: *requestType
args:
  function:
    schema: *schema
    name: *functionName
  source: *source
|]

-- | Unified untrack function
untrackFunction :: HasCallStack => String -> String -> TestEnvironment -> IO ()
untrackFunction source functionName testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
      schema = getSchemaName testEnvironment
  let requestType = backendType <> "_untrack_function"
  GraphqlEngine.postMetadata_
    testEnvironment
    [yaml|
type: *requestType
args:
  source: *source
  function:
    schema: *schema
    name: *functionName
|]

trackComputedField ::
  HasCallStack =>
  String ->
  Table ->
  String ->
  String ->
  Aeson.Value ->
  Aeson.Value ->
  TestEnvironment ->
  IO ()
trackComputedField source Table {tableName} functionName asFieldName argumentMapping returnTable testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
      schema = getSchemaName testEnvironment
      schemaKey = BackendType.backendSchemaKeyword backendTypeMetadata
      requestType = backendType <> "_add_computed_field"
  GraphqlEngine.postMetadata_
    testEnvironment
    [yaml|
type: *requestType
args:
  source: *source
  comment: null
  table:
    *schemaKey: *schema
    name: *tableName
  name: *asFieldName
  definition:
    function:
      *schemaKey: *schema
      name: *functionName
    table_argument: null
    session_argument: null
    argument_mapping: *argumentMapping
    return_table: *returnTable
|]

-- | Unified untrack computed field
untrackComputedField :: HasCallStack => String -> Table -> String -> TestEnvironment -> IO ()
untrackComputedField source Table {tableName} fieldName testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
      schema = getSchemaName testEnvironment
      schemaKey = BackendType.backendSchemaKeyword backendTypeMetadata
  let requestType = backendType <> "_drop_computed_field"

  GraphqlEngine.postMetadata_
    testEnvironment
    [yaml|
      type: *requestType
      args:
        source: *source
        table:
          *schemaKey: *schema
          name: *tableName
        name: *fieldName
      |]

-- | Helper to create the object relationship name
mkObjectRelationshipName :: Reference -> Text
mkObjectRelationshipName Reference {referenceLocalColumn, referenceTargetTable, referenceTargetColumn, referenceTargetQualifiers} =
  let columnName = case resolveReferenceSchema referenceTargetQualifiers of
        Just (SchemaName targetSchema) -> targetSchema <> "_" <> referenceTargetColumn
        Nothing -> referenceTargetColumn
   in referenceTargetTable <> "_by_" <> referenceLocalColumn <> "_to_" <> columnName

-- | Build an 'Aeson.Value' representing a 'BackendType' specific @TableName@.
mkTableField :: BackendTypeConfig -> SchemaName -> Text -> Aeson.Value
mkTableField backendTypeMetadata schemaName tableName =
  let dcFieldName = Aeson.Array $ V.fromList [Aeson.String (unSchemaName schemaName), Aeson.String tableName]
      nativeFieldName = Aeson.object [BackendType.backendSchemaKeyword backendTypeMetadata .= Aeson.String (unSchemaName schemaName), "name" .= Aeson.String tableName]
   in case BackendType.backendType backendTypeMetadata of
        BackendType.Postgres -> nativeFieldName
        BackendType.SQLServer -> nativeFieldName
        BackendType.BigQuery -> nativeFieldName
        BackendType.Citus -> nativeFieldName
        BackendType.Cockroach -> nativeFieldName
        BackendType.DataConnector _ -> dcFieldName

-- | Unified track object relationships
trackObjectRelationships :: HasCallStack => Table -> TestEnvironment -> IO ()
trackObjectRelationships tbl@(Table {tableName, tableReferences, tableManualRelationships}) testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      localSchema = resolveTableSchema testEnvironment tbl
      backendType = BackendType.backendTypeString backendTypeMetadata
      source = BackendType.backendSourceName backendTypeMetadata
      tableField = mkTableField backendTypeMetadata localSchema tableName
      requestType = backendType <> "_create_object_relationship"

  for_ tableReferences $ \ref@Reference {referenceLocalColumn} -> do
    let relationshipName = mkObjectRelationshipName ref
    GraphqlEngine.postMetadata_
      testEnvironment
      [yaml|
        type: *requestType
        args:
          source: *source
          table: *tableField
          name: *relationshipName
          using:
            foreign_key_constraint_on: *referenceLocalColumn
      |]

  for_ tableManualRelationships $ \ref@Reference {referenceLocalColumn, referenceTargetTable, referenceTargetColumn, referenceTargetQualifiers} -> do
    let targetSchema = case resolveReferenceSchema referenceTargetQualifiers of
          Just schema -> schema
          Nothing -> getSchemaName testEnvironment
        relationshipName = mkObjectRelationshipName ref
        targetTableField = mkTableField backendTypeMetadata targetSchema referenceTargetTable
        manualConfiguration :: Aeson.Value
        manualConfiguration =
          Aeson.object
            [ "remote_table" .= targetTableField,
              "column_mapping"
                .= Aeson.object [K.fromText referenceLocalColumn .= referenceTargetColumn]
            ]
        payload =
          [yaml|
            type: *requestType
            args:
              source: *source
              table: *tableField
              name: *relationshipName
              using:
                manual_configuration: *manualConfiguration
          |]

    GraphqlEngine.postMetadata_ testEnvironment payload

-- | Helper to create the array relationship name
mkArrayRelationshipName :: Text -> Text -> Text -> [Text] -> Text
mkArrayRelationshipName tableName referenceLocalColumn referenceTargetColumn referenceTargetQualifiers =
  let columnName = case resolveReferenceSchema referenceTargetQualifiers of
        Just (SchemaName targetSchema) -> targetSchema <> "_" <> referenceTargetColumn
        Nothing -> referenceTargetColumn
   in tableName <> "s_by_" <> referenceLocalColumn <> "_to_" <> columnName

-- | Unified track array relationships
trackArrayRelationships :: HasCallStack => Table -> TestEnvironment -> IO ()
trackArrayRelationships tbl@(Table {tableName, tableReferences, tableManualRelationships}) testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      localSchema = resolveTableSchema testEnvironment tbl
      backendType = BackendType.backendTypeString backendTypeMetadata
      source = BackendType.backendSourceName backendTypeMetadata
      tableField = mkTableField backendTypeMetadata localSchema tableName
      requestType = backendType <> "_create_array_relationship"

  for_ tableReferences $ \Reference {referenceLocalColumn, referenceTargetTable, referenceTargetColumn, referenceTargetQualifiers} -> do
    let targetSchema = case resolveReferenceSchema referenceTargetQualifiers of
          Just schema -> schema
          Nothing -> getSchemaName testEnvironment
        relationshipName = mkArrayRelationshipName tableName referenceTargetColumn referenceLocalColumn referenceTargetQualifiers
        targetTableField = mkTableField backendTypeMetadata targetSchema referenceTargetTable
    GraphqlEngine.postMetadata_
      testEnvironment
      [yaml|
        type: *requestType
        args:
          source: *source
          table: *targetTableField
          name: *relationshipName
          using:
            foreign_key_constraint_on:
              table: *tableField
              column: *referenceLocalColumn
      |]

  for_ tableManualRelationships $ \Reference {referenceLocalColumn, referenceTargetTable, referenceTargetColumn, referenceTargetQualifiers} -> do
    let targetSchema = case resolveReferenceSchema referenceTargetQualifiers of
          Just schema -> schema
          Nothing -> getSchemaName testEnvironment
        relationshipName = mkArrayRelationshipName tableName referenceTargetColumn referenceLocalColumn referenceTargetQualifiers
        targetTableField = mkTableField backendTypeMetadata targetSchema referenceTargetTable
        manualConfiguration :: Aeson.Value
        manualConfiguration =
          Aeson.object
            [ "remote_table"
                .= tableField,
              "column_mapping"
                .= Aeson.object [K.fromText referenceTargetColumn .= referenceLocalColumn]
            ]
        payload =
          [yaml|
type: *requestType
args:
  source: *source
  table: *targetTableField
  name: *relationshipName
  using:
    manual_configuration: *manualConfiguration
|]

    GraphqlEngine.postMetadata_ testEnvironment payload

-- | Unified untrack relationships
untrackRelationships :: HasCallStack => Table -> TestEnvironment -> IO ()
untrackRelationships Table {tableName, tableReferences, tableManualRelationships} testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      schema = getSchemaName testEnvironment
      source = BackendType.backendSourceName backendTypeMetadata
      backendType = BackendType.backendTypeString backendTypeMetadata
      tableField = mkTableField backendTypeMetadata schema tableName
      requestType = backendType <> "_drop_relationship"

  forFinally_ (tableManualRelationships <> tableReferences) $ \ref@Reference {referenceLocalColumn, referenceTargetTable, referenceTargetColumn, referenceTargetQualifiers} -> do
    let arrayRelationshipName = mkArrayRelationshipName tableName referenceTargetColumn referenceLocalColumn referenceTargetQualifiers
        objectRelationshipName = mkObjectRelationshipName ref
        targetTableField = mkTableField backendTypeMetadata schema referenceTargetTable
    finally
      ( -- drop array relationship
        GraphqlEngine.postMetadata_
          testEnvironment
          [yaml|
    type: *requestType
    args:
      source: *source
      table: *targetTableField
      relationship: *arrayRelationshipName
    |]
      )
      ( -- drop object relationship
        GraphqlEngine.postMetadata_
          testEnvironment
          [yaml|
    type: *requestType
    args:
      source: *source
      table: *tableField
      relationship: *objectRelationshipName
    |]
      )

-- | Unified RunSQL
runSQL :: HasCallStack => String -> String -> TestEnvironment -> IO ()
runSQL source sql testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      prefix = BackendType.backendTypeString backendTypeMetadata
      requestType = prefix <> "_run_sql"
  GraphqlEngine.postV2Query_
    testEnvironment
    [yaml|
type: *requestType
args:
  source: *source
  sql: *sql
  cascade: false
  read_only: false
|]

addSource :: HasCallStack => Text -> Value -> TestEnvironment -> IO ()
addSource sourceName sourceConfig testEnvironment = do
  let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
      backendType = BackendType.backendTypeString backendTypeMetadata
  GraphqlEngine.postMetadata_
    testEnvironment
    [interpolateYaml|
      type: #{ backendType }_add_source
      args:
        name: #{ sourceName }
        configuration: #{ sourceConfig }
      |]
