select *
from {{ source('raw', 'raw_ab_test_metadata') }}
limit 10