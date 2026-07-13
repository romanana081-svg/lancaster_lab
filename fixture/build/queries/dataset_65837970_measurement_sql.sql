
    SELECT
        measurement.person_id,
        measurement.measurement_concept_id,
        m_standard_concept.concept_name as standard_concept_name,
        m_standard_concept.concept_code as standard_concept_code,
        m_standard_concept.vocabulary_id as standard_vocabulary,
        measurement.measurement_datetime,
        measurement.measurement_type_concept_id,
        m_type.concept_name as measurement_type_concept_name,
        measurement.operator_concept_id,
        m_operator.concept_name as operator_concept_name,
        measurement.value_as_number,
        measurement.value_as_concept_id,
        m_value.concept_name as value_as_concept_name,
        measurement.unit_concept_id,
        m_unit.concept_name as unit_concept_name,
        measurement.range_low,
        measurement.range_high,
        measurement.visit_occurrence_id,
        m_visit.concept_name as visit_occurrence_concept_name,
        measurement.measurement_source_value,
        measurement.measurement_source_concept_id,
        m_source_concept.concept_name as source_concept_name,
        m_source_concept.concept_code as source_concept_code,
        m_source_concept.vocabulary_id as source_vocabulary,
        measurement.unit_source_value,
        measurement.value_source_value 
    FROM
        ( SELECT
            * 
        FROM
            `measurement` measurement 
        WHERE
            (
                measurement_concept_id IN (
                    SELECT
                        DISTINCT c.concept_id 
                    FROM
                        `cb_criteria` c 
                    JOIN
                        (
                            SELECT
                                CAST(cr.id as string) AS id       
                            FROM
                                `cb_criteria` cr       
                            WHERE
                                concept_id IN (
                                    3022192, 37026687
                                )       
                                AND full_text LIKE '%_rank1]%'      
                        ) a 
                            ON (
                                c.path LIKE CONCAT('%.',
                            a.id,
                            '.%') 
                            OR c.path LIKE CONCAT('%.',
                            a.id) 
                            OR c.path LIKE CONCAT(a.id,
                            '.%') 
                            OR c.path = a.id) 
                        WHERE
                            is_standard = 1 
                            AND is_selectable = 1
                        )
                )  
                AND (
                    measurement.PERSON_ID IN (
                        SELECT
                            distinct person_id  
                        FROM
                            `cb_search_person` cb_search_person  
                        WHERE
                            cb_search_person.person_id IN (
                                SELECT
                                    person_id 
                                FROM
                                    `cb_search_person` p 
                                WHERE
                                    has_whole_genome_variant = 1 
                            ) 
                        )
                )
            ) measurement 
        LEFT JOIN
            `concept` m_standard_concept 
                ON measurement.measurement_concept_id = m_standard_concept.concept_id 
        LEFT JOIN
            `concept` m_type 
                ON measurement.measurement_type_concept_id = m_type.concept_id 
        LEFT JOIN
            `concept` m_operator 
                ON measurement.operator_concept_id = m_operator.concept_id 
        LEFT JOIN
            `concept` m_value 
                ON measurement.value_as_concept_id = m_value.concept_id 
        LEFT JOIN
            `concept` m_unit 
                ON measurement.unit_concept_id = m_unit.concept_id 
        LEFT JOIn
            `visit_occurrence` v 
                ON measurement.visit_occurrence_id = v.visit_occurrence_id 
        LEFT JOIN
            `concept` m_visit 
                ON v.visit_concept_id = m_visit.concept_id 
        LEFT JOIN
            `concept` m_source_concept 
                ON measurement.measurement_source_concept_id = m_source_concept.concept_id