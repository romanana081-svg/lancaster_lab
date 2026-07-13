
    SELECT
        c_occurrence.person_id,
        c_occurrence.condition_concept_id,
        c_standard_concept.concept_name as standard_concept_name,
        c_standard_concept.concept_code as standard_concept_code,
        c_standard_concept.vocabulary_id as standard_vocabulary,
        c_occurrence.condition_start_datetime,
        c_occurrence.condition_end_datetime,
        c_occurrence.condition_type_concept_id,
        c_type.concept_name as condition_type_concept_name,
        c_occurrence.stop_reason,
        c_occurrence.visit_occurrence_id,
        visit.concept_name as visit_occurrence_concept_name,
        c_occurrence.condition_source_value,
        c_occurrence.condition_source_concept_id,
        c_source_concept.concept_name as source_concept_name,
        c_source_concept.concept_code as source_concept_code,
        c_source_concept.vocabulary_id as source_vocabulary,
        c_occurrence.condition_status_source_value,
        c_occurrence.condition_status_concept_id,
        c_status.concept_name as condition_status_concept_name 
    FROM
        ( SELECT
            * 
        FROM
            `condition_occurrence` c_occurrence 
        WHERE
            (
                condition_source_concept_id IN (
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
                                    1326588, 1569127, 1569134, 1569135, 1569145, 35207684, 35207685, 35207686, 35207687, 35207688, 35207689, 35207691, 35207692, 35207693, 35207695, 35207696, 35207697, 35207698, 35207699, 35207700, 35207701, 35207702, 35207704, 35207705, 35207706, 44819697, 44819699, 44819700, 44819702, 44820857, 44820858, 44820859, 44820860, 44820861, 44820862, 44820863, 44820864, 44823111, 44823120, 44824237, 44825428, 44825429, 44825430, 44826635, 44826636, 44826643, 44827782, 44827783, 44828972, 44828973, 44830079, 44830080, 44831236, 44831237, 44831238, 44832372, 44832373, 44832374, 44832375, 44832376, 44833561, 44834718, 44834719, 44834720, 44834721, 44834723, 44834724, 44834725, 44834733, 44835926, 44835927, 44835928, 44835929, 44835932, 44837099, 45533436, 45548013, 45557536, 45562340, 45562344, 45567167, 45567168, 45572079, 45572080, 45576865, 45576866, 45586572, 45591456, 45596197, 45596199, 45601024, 45605779, 45605781, 45605787, 45605788
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
                            is_standard = 0 
                            AND is_selectable = 1
                        )
                )  
                AND (
                    c_occurrence.PERSON_ID IN (
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
            ) c_occurrence 
        LEFT JOIN
            `concept` c_standard_concept 
                ON c_occurrence.condition_concept_id = c_standard_concept.concept_id 
        LEFT JOIN
            `concept` c_type 
                ON c_occurrence.condition_type_concept_id = c_type.concept_id 
        LEFT JOIN
            `visit_occurrence` v 
                ON c_occurrence.visit_occurrence_id = v.visit_occurrence_id 
        LEFT JOIN
            `concept` visit 
                ON v.visit_concept_id = visit.concept_id 
        LEFT JOIN
            `concept` c_source_concept 
                ON c_occurrence.condition_source_concept_id = c_source_concept.concept_id 
        LEFT JOIN
            `concept` c_status 
                ON c_occurrence.condition_status_concept_id = c_status.concept_id